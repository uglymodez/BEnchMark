#import <Cocoa/Cocoa.h>
#include <sys/sysctl.h>
#include <math.h>
#include "benchmark.h"
#import "report.h"

static NSColor *OperationColor(mb_operation op) {
    switch (op) {
        case MB_READ: return [NSColor colorWithRed:0.35 green:0.92 blue:0.77 alpha:1];
        case MB_WRITE: return [NSColor colorWithRed:0.30 green:0.72 blue:1 alpha:1];
        case MB_EXECUTE: return [NSColor colorWithRed:1 green:0.77 blue:0.35 alpha:1];
        case MB_LATENCY: return [NSColor colorWithRed:0.77 green:0.59 blue:1 alpha:1];
    }
    return NSColor.labelColor;
}
static NSString *ThermalName(NSProcessInfoThermalState state) {
    switch (state) {
        case NSProcessInfoThermalStateNominal: return @"нормальная температура";
        case NSProcessInfoThermalStateFair: return @"умеренный нагрев";
        case NSProcessInfoThermalStateSerious: return @"сильный нагрев";
        case NSProcessInfoThermalStateCritical: return @"критический нагрев";
    }
    return @"температурный статус неизвестен";
}
static NSString *SizeLabel(uint64_t n) {
    if (n>=1024ULL*1024*1024) return [NSString stringWithFormat:@"%.2g GiB",n/(1024.0*1024*1024)];
    if (n>=1024*1024) return [NSString stringWithFormat:@"%.3g MiB",n/(1024.0*1024)];
    return [NSString stringWithFormat:@"%.3g KiB",n/1024.0];
}
static uint64_t SysNumber(const char *key) {
    uint64_t result=0; size_t size=sizeof(result);
    return sysctlbyname(key,&result,&size,NULL,0)==0 ? result : 0;
}
static NSString *SysString(const char *key) {
    char text[256]={0}; size_t size=sizeof(text);
    if (sysctlbyname(key,text,&size,NULL,0)!=0) return @"";
    text[sizeof(text)-1]=0; return [NSString stringWithUTF8String:text] ?: @"";
}
static NSString *CacheDescription(void) {
    NSMutableArray *lines=[NSMutableArray array];
    uint64_t levels=SysNumber("hw.nperflevels");
    if (levels>0 && levels<8) {
        for (unsigned i=0; i<levels; ++i) {
            NSString *prefix=[NSString stringWithFormat:@"hw.perflevel%u",i];
            NSString *name=SysString([[prefix stringByAppendingString:@".name"] UTF8String]);
            NSMutableArray *parts=[NSMutableArray array];
            for (NSString *key in @[@"l1icachesize",@"l1dcachesize",@"l2cachesize",@"l3cachesize"]) {
                uint64_t n=SysNumber([[prefix stringByAppendingFormat:@".%@",key] UTF8String]);
                if (n) [parts addObject:[NSString stringWithFormat:@"%@ %@",[key substringToIndex:([key hasPrefix:@"l1"]?3:2)].uppercaseString,SizeLabel(n)]];
            }
            if (parts.count) [lines addObject:[NSString stringWithFormat:@"%@: %@",name.length?name:prefix,[parts componentsJoinedByString:@" · "]]];
        }
    } else {
        for (NSString *key in @[@"l1icachesize",@"l1dcachesize",@"l2cachesize",@"l3cachesize"]) {
            uint64_t n=SysNumber([[ @"hw." stringByAppendingString:key] UTF8String]);
            if (n) [lines addObject:[NSString stringWithFormat:@"%@: %@",[key substringToIndex:([key hasPrefix:@"l1"]?3:2)].uppercaseString,SizeLabel(n)]];
        }
    }
    return lines.count ? [lines componentsJoinedByString:@"  |  "] : @"Размеры кэшей не предоставлены macOS";
}
static NSTextField *Label(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label=[NSTextField labelWithString:text];
    label.font=[NSFont systemFontOfSize:size weight:weight]; label.textColor=color;
    label.lineBreakMode=NSLineBreakByTruncatingTail; label.selectable=YES;
    return label;
}

/* Draw an opaque header so bitmap exports and appearance changes preserve
   contrast instead of depending on the window's vibrancy backdrop. */
@interface MBHeaderCell : NSTableHeaderCell
@end
@implementation MBHeaderCell
- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view {
    [view.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [NSColor.controlBackgroundColor setFill]; NSRectFill(frame);
        NSDictionary *attributes=@{NSFontAttributeName:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium],NSForegroundColorAttributeName:NSColor.secondaryLabelColor};
        [self.stringValue drawInRect:NSInsetRect(frame,6,4) withAttributes:attributes];
    }];
}
@end

@interface MBPoint : NSObject
@property mb_result result;
@end
@implementation MBPoint
@end

@interface MBChart : NSView
@property NSMutableArray<MBPoint *> *points;
@property NSArray<MBPoint *> *baseline;
@property NSInteger mode;
@property size_t maximum, selectedBytes;
@property NSTrackingArea *tracking;
@end
@implementation MBChart
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self=[super initWithFrame:frame])) { _points=[NSMutableArray array]; _maximum=256*1024*1024; }
    return self;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.tracking) [self removeTrackingArea:self.tracking];
    self.tracking=[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved|NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.tracking];
}
- (void)mouseMoved:(NSEvent *)event {
    NSPoint mouse=[self convertPoint:event.locationInWindow fromView:nil];
    double fraction=fmax(0,fmin(1,(mouse.x-64)/MAX(1,self.bounds.size.width-88)));
    double target=log2(4096.0)+fraction*log2((double)self.maximum/4096);
    double nearest=INFINITY; self.selectedBytes=0;
    for (MBPoint *p in self.points) {
        double distance=fabs(log2((double)p.result.bytes)-target);
        if (distance<nearest) { nearest=distance; self.selectedBytes=p.result.bytes; }
    }
    [self setNeedsDisplay:YES];
}
- (void)mouseExited:(NSEvent *)event { (void)event; self.selectedBytes=0; [self setNeedsDisplay:YES]; }
- (void)text:(NSString *)s at:(NSPoint)p color:(NSColor *)color size:(CGFloat)size {
    [s drawAtPoint:p withAttributes:@{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular],NSForegroundColorAttributeName:color}];
}
- (NSPoint)position:(mb_result)r value:(double)value plot:(NSRect)plot high:(double)high {
    return NSMakePoint(plot.origin.x+plot.size.width*log2((double)r.bytes/4096)/fmax(1,log2((double)self.maximum/4096)),NSMaxY(plot)-plot.size.height*value/high);
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [[NSColor colorWithRed:0.035 green:0.055 blue:0.09 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:14 yRadius:14] fill];
    CGFloat w=self.bounds.size.width, h=self.bounds.size.height;
    NSRect plot=NSMakeRect(64,76,MAX(1,w-88),MAX(1,h-120));
    double high=1;
    for (NSArray *series in @[self.points,self.baseline ?: @[]])
        for (MBPoint *p in series) { mb_result r=p.result; high=fmax(high,(series==self.points?mb_result_maximum(&r):mb_result_value(&r))*1.12); }
    double magnitude=pow(10,floor(log10(high/5))), step=ceil(high/5/magnitude)*magnitude; high=step*5;
    NSColor *grid=[NSColor colorWithWhite:1 alpha:0.09], *muted=[NSColor colorWithRed:0.51 green:0.61 blue:0.74 alpha:1];
    double maxLog=fmax(1,log2((double)self.maximum/4096));
    for (int j=0;j<=5;++j) {
        CGFloat y=plot.origin.y+plot.size.height*(1-j/5.0);
        NSBezierPath *line=[NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(plot.origin.x,y)]; [line lineToPoint:NSMakePoint(NSMaxX(plot),y)];
        [grid setStroke]; line.lineWidth=0.6; [line stroke];
        [self text:[NSString stringWithFormat:@"%5.1f",j*step] at:NSMakePoint(5,y-7) color:muted size:10];
    }
    int labelStride=MAX(1,(int)ceil((maxLog+1)*65/plot.size.width));
    for (int k=0;k<=maxLog;++k) {
        CGFloat x=plot.origin.x+plot.size.width*k/maxLog;
        NSBezierPath *line=[NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(x,plot.origin.y)]; [line lineToPoint:NSMakePoint(x,NSMaxY(plot))];
        [grid setStroke]; line.lineWidth=0.6; [line stroke];
        if (k%labelStride==0) [self text:SizeLabel((uint64_t)4096<<k) at:NSMakePoint(x-19,NSMaxY(plot)+10) color:muted size:10];
    }
    [self text:self.mode==3?@"ns/load":@"GB/s" at:NSMakePoint(12,57) color:muted size:10];
    [self text:@"РАБОЧИЙ НАБОР · LOG₂" at:NSMakePoint(w-192,h-17) color:muted size:9];
    NSString *legend=@[@"● ЧТЕНИЕ",@"● ЧТЕНИЕ ПАМЯТИ",@"● ЗАПИСЬ ПАМЯТИ",@"● ЗАДЕРЖКА · МЕНЬШЕ ЛУЧШЕ"][self.mode];
    [self text:legend at:NSMakePoint(20,16) color:OperationColor(self.mode==2?MB_WRITE:self.mode==3?MB_LATENCY:MB_READ) size:12];
    if (self.mode==0) [self text:@"● КОД*" at:NSMakePoint(180,16) color:OperationColor(MB_EXECUTE) size:12];
    [self text:self.baseline.count?@"ПУНКТИР — ЭТАЛОН":@"ПОЛОСА — MIN–MAX" at:NSMakePoint(w-198,18) color:muted size:10];
    for (int op=MB_READ;op<=MB_LATENCY;++op) {
        NSColor *color=OperationColor((mb_operation)op);
        NSMutableArray<MBPoint *> *current=[NSMutableArray array];
        for (MBPoint *p in self.points) if (p.result.operation==(mb_operation)op) [current addObject:p];
        if (current.count>1) {
            NSBezierPath *band=[NSBezierPath bezierPath]; BOOL first=YES;
            for (MBPoint *p in current) {
                mb_result r=p.result; NSPoint point=[self position:r value:mb_result_minimum(&r) plot:plot high:high];
                if (first) { [band moveToPoint:point]; first=NO; } else [band lineToPoint:point];
            }
            for (MBPoint *p in current.reverseObjectEnumerator) {
                mb_result r=p.result; [band lineToPoint:[self position:r value:mb_result_maximum(&r) plot:plot high:high]];
            }
            [band closePath]; [[color colorWithAlphaComponent:0.14] setFill]; [band fill];
        }
        for (NSUInteger pass=0;pass<2;++pass) {
            NSArray *series=pass==0?(self.baseline ?: @[]):current;
            NSBezierPath *path=[NSBezierPath bezierPath]; path.lineWidth=pass==0?1.4:2.3;
            if (!pass) { CGFloat dash[]={5,5}; [path setLineDash:dash count:2 phase:0]; }
            [[color colorWithAlphaComponent:pass==0?0.45:1] setStroke]; BOOL first=YES;
            for (MBPoint *p in series) {
                mb_result r=p.result; if (r.operation!=(mb_operation)op) continue;
                NSPoint point=[self position:r value:mb_result_value(&r) plot:plot high:high];
                if (first) { [path moveToPoint:point]; first=NO; } else [path lineToPoint:point];
                if (pass) { [color setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(point.x-2,point.y-2,4,4)] fill]; }
            }
            [path stroke];
        }
    }
    if (self.selectedBytes) {
        NSMutableArray *details=[NSMutableArray arrayWithObject:SizeLabel(self.selectedBytes)];
        for (MBPoint *p in self.points) if (p.result.bytes==self.selectedBytes) {
            mb_result r=p.result;
            [details addObject:[NSString stringWithFormat:@"%s %.2f %s · CV %.1f%%",mb_operation_name(r.operation),mb_result_value(&r),mb_operation_unit(r.operation),r.cv_percent]];
            NSPoint point=[self position:r value:mb_result_value(&r) plot:plot high:high];
            [OperationColor(r.operation) setStroke]; NSBezierPath *ring=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(point.x-5,point.y-5,10,10)]; [ring stroke];
        }
        [self text:[details componentsJoinedByString:@"  /  "] at:NSMakePoint(20,40) color:NSColor.whiteColor size:11];
    } else [self text:@"Наведи на график или выбери строку таблицы для точного значения" at:NSMakePoint(20,40) color:muted size:10];
    if (!self.points.count) {
        [self text:@"Начни тест, чтобы увидеть профиль памяти своего Mac" at:NSMakePoint(MAX(70,(w-455)/2),h/2) color:muted size:13];
    }
}
@end

@interface MBContent : NSView
@property NSTextField *titleLabel, *machineLabel, *cacheLabel, *rangeLabel, *profileLabel, *statusLabel, *noteLabel, *conditionLabel;
@property NSSegmentedControl *tabs;
@property NSPopUpButton *maximumPopup, *profilePopup;
@property NSButton *startButton, *exportButton, *jsonButton, *baselineButton;
@property NSProgressIndicator *progress;
@property MBChart *chart;
@property NSScrollView *tableScroll, *aboutScroll;
@property NSArray<NSTextField *> *stats;
@property BOOL showingAbout;
@end
@implementation MBContent
- (void)drawRect:(NSRect)dirty { [NSColor.windowBackgroundColor setFill]; NSRectFill(dirty); }
- (BOOL)isFlipped { return YES; }
- (void)layout {
    [super layout]; CGFloat w=self.bounds.size.width, h=self.bounds.size.height, gap=24;
    self.titleLabel.frame=NSMakeRect(gap,19,320,34);
    self.machineLabel.frame=NSMakeRect(gap,58,w-2*gap,21);
    self.cacheLabel.frame=NSMakeRect(gap,84,w-2*gap,18);
    self.conditionLabel.frame=NSMakeRect(gap,110,w-2*gap,18);
    self.tabs.frame=NSMakeRect(gap,144,520,28);
    self.rangeLabel.frame=NSMakeRect(w-413,147,65,22);
    self.maximumPopup.frame=NSMakeRect(w-348,141,112,32);
    self.profileLabel.frame=NSMakeRect(w-224,147,42,22);
    self.profilePopup.frame=NSMakeRect(w-181,141,157,32);
    CGFloat chartHeight=h-474;
    self.chart.frame=NSMakeRect(gap,184,w-2*gap,chartHeight);
    CGFloat y=184+chartHeight+14;
    for (NSUInteger i=0;i<self.stats.count;++i) self.stats[i].frame=NSMakeRect(gap+i*(w-2*gap)/3,y,(w-2*gap)/3-10,42);
    self.tableScroll.frame=NSMakeRect(gap,y+52,w-2*gap,106);
    self.noteLabel.frame=NSMakeRect(gap,h-110,w-2*gap,32);
    self.startButton.frame=NSMakeRect(w-178,h-47,154,30);
    self.baselineButton.frame=NSMakeRect(gap,h-47,192,30);
    self.exportButton.frame=NSMakeRect(gap+204,h-47,120,30);
    self.jsonButton.frame=NSMakeRect(gap+336,h-47,120,30);
    self.progress.frame=NSMakeRect(gap,h-12,w-2*gap,4);
    self.statusLabel.frame=NSMakeRect(gap,h-72,w-2*gap,20);
    self.aboutScroll.frame=NSMakeRect(gap,184,w-2*gap,h-290);
    self.chart.hidden=self.showingAbout; self.tableScroll.hidden=self.showingAbout;
    self.noteLabel.hidden=self.showingAbout; self.aboutScroll.hidden=!self.showingAbout;
    for (NSTextField *label in self.stats) label.hidden=self.showingAbout;
}
@end

@interface MBApp : NSObject <NSApplicationDelegate,NSTableViewDataSource,NSTableViewDelegate>
@property NSWindow *window;
@property MBContent *content;
@property NSTableView *table;
@property NSMutableArray<MBPoint *> *points;
@property NSMutableDictionary<NSNumber *,NSArray<MBPoint *> *> *resultsByMode;
@property NSMutableDictionary<NSNumber *,NSDictionary *> *metadataByMode;
@property mb_context *context;
@property BOOL running, smokeTest;
@property NSUInteger smokePass;
@property NSInteger selectedMode;
@property id activity;
@property NSMutableDictionary<NSNumber *, NSDictionary *> *baselines;
@property NSTimer *conditionTimer;
@end

@implementation MBApp
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    self.smokeTest=[NSProcessInfo.processInfo.arguments containsObject:@"--smoke-test"];
    self.points=[NSMutableArray array]; self.resultsByMode=[NSMutableDictionary dictionary]; self.metadataByMode=[NSMutableDictionary dictionary];
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1080,800) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"Memory Benchmark — Mac";
    self.window.minSize=NSMakeSize(1000,760); self.window.releasedWhenClosed=NO;
    self.window.backgroundColor=NSColor.windowBackgroundColor;
    self.content=[[MBContent alloc] initWithFrame:self.window.contentView.bounds];
    self.content.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    self.window.contentView=self.content; MBContent *v=self.content;
    NSColor *dark=NSColor.labelColor, *muted=[NSColor secondaryLabelColor];
    v.titleLabel=Label(@"Memory Lab  /  2.0",27,NSFontWeightSemibold,dark);
    NSString *cpu=SysString("machdep.cpu.brand_string"); if (!cpu.length) cpu=SysString("hw.model");
    NSString *translation=SysNumber("sysctl.proc_translated")?@" · Rosetta: пересобери под arm64":@" · native";
    v.machineLabel=Label([NSString stringWithFormat:@"%@  ·  %@ RAM  ·  %@%@  ·  macOS %@",cpu,SizeLabel(NSProcessInfo.processInfo.physicalMemory),[NSString stringWithUTF8String:mb_architecture()],translation,NSProcessInfo.processInfo.operatingSystemVersionString],12,NSFontWeightMedium,dark);
    v.machineLabel.toolTip=v.machineLabel.stringValue;
    v.cacheLabel=Label(CacheDescription(),11,NSFontWeightRegular,muted); v.cacheLabel.toolTip=[v.cacheLabel.stringValue stringByAppendingString:@". Сведения macOS; L2 может быть общим для группы ядер. Они не определяют, на каком ядре идёт тест."];
    v.tabs=[NSSegmentedControl segmentedControlWithLabels:@[@"Cache Speed",@"Read RAM",@"Write RAM",@"Latency",@"О программе"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeTab:)];
    v.tabs.selectedSegment=0;
    v.rangeLabel=Label(@"До",12,NSFontWeightRegular,muted);
    v.maximumPopup=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [v.maximumPopup addItemsWithTitles:@[@"64 MiB",@"256 MiB",@"512 MiB",@"1 GiB"]]; [v.maximumPopup selectItemAtIndex:1];
    v.profileLabel=Label(@"Тест",12,NSFontWeightRegular,muted);
    v.profilePopup=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [v.profilePopup addItemsWithTitles:@[@"Быстрый · 3",@"Баланс · 5",@"Точный · 9"]];
    [v.profilePopup selectItemAtIndex:1];
    v.chart=[[MBChart alloc] initWithFrame:NSZeroRect];
    [v.chart setAccessibilityElement:YES]; [v.chart setAccessibilityLabel:@"График скорости по размеру буфера. Те же измерения доступны в таблице ниже."];
    NSMutableArray *stats=[NSMutableArray array];
    for (NSString *s in @[@"Чтение: —",@"Выполнение*: —",@"Размер буфера: —"]) {
        NSTextField *label=Label(s,16,NSFontWeightMedium,dark); label.maximumNumberOfLines=2;
        [stats addObject:label]; [v addSubview:label];
    }
    v.stats=stats;
    self.table=[[NSTableView alloc] initWithFrame:NSZeroRect]; self.table.dataSource=self; self.table.delegate=self;
    self.table.usesAlternatingRowBackgroundColors=YES; self.table.rowHeight=24;
    self.table.columnAutoresizingStyle=NSTableViewUniformColumnAutoresizingStyle;
    NSArray *titles=@[@"Буфер",@"Операция",@"Медиана",@"Мин. — макс.",@"CV, %",@"К эталону"];
    for (NSUInteger i=0;i<titles.count;++i) {
        NSTableColumn *column=[[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%lu",(unsigned long)i]];
        column.headerCell=[[MBHeaderCell alloc] initTextCell:titles[i]]; column.title=titles[i]; column.width=i==1?190:150; [self.table addTableColumn:column];
    }
    v.tableScroll=[[NSScrollView alloc] initWithFrame:NSZeroRect]; v.tableScroll.documentView=self.table;
    v.tableScroll.hasVerticalScroller=YES; v.tableScroll.borderType=NSBezelBorder;
    v.noteLabel=Label(@"* Выполнение: объём NOP-кода / время; это не прямая скорость I-cache. Один поток, медиана 3 замеров. GB/s = 10⁹ байт/с.",11,NSFontWeightRegular,muted);
    v.noteLabel.maximumNumberOfLines=2; v.noteLabel.lineBreakMode=NSLineBreakByWordWrapping;
    v.statusLabel=Label(@"Готов к тесту · закрой тяжёлые приложения",12,NSFontWeightRegular,muted);
    v.progress=[[NSProgressIndicator alloc] initWithFrame:NSZeroRect]; v.progress.indeterminate=NO; v.progress.minValue=0; v.progress.maxValue=1;
    v.startButton=[NSButton buttonWithTitle:@"Начать тест" target:self action:@selector(startOrStop:)]; v.startButton.bezelStyle=NSBezelStyleRounded; v.startButton.keyEquivalent=@"\r";
    v.exportButton=[NSButton buttonWithTitle:@"Экспорт CSV" target:self action:@selector(exportCSV:)]; v.exportButton.bezelStyle=NSBezelStyleRounded; v.exportButton.enabled=NO;
    v.jsonButton=[NSButton buttonWithTitle:@"Экспорт JSON" target:self action:@selector(exportJSON:)]; v.jsonButton.bezelStyle=NSBezelStyleRounded; v.jsonButton.enabled=NO;
    v.baselineButton=[NSButton buttonWithTitle:@"Сохранить как эталон" target:self action:@selector(saveBaseline:)]; v.baselineButton.bezelStyle=NSBezelStyleRounded; v.baselineButton.enabled=NO;
    v.baselineButton.toolTip=@"Сохранить завершённый прогон этой вкладки для сравнения. Эталон остаётся после перезапуска приложения.";
    v.conditionLabel=Label(@"",11,NSFontWeightMedium,muted);
    v.aboutScroll=[[NSScrollView alloc] initWithFrame:NSZeroRect]; v.aboutScroll.hasVerticalScroller=YES;
    NSTextView *about=[[NSTextView alloc] initWithFrame:NSMakeRect(0,0,960,650)]; about.editable=NO; about.selectable=YES;
    about.font=[NSFont systemFontOfSize:14]; about.backgroundColor=self.window.backgroundColor;
    about.textContainerInset=NSMakeSize(12,12); about.autoresizingMask=NSViewWidthSizable; about.textContainer.widthTracksTextView=YES;
    about.string=@"Memory Lab · 2.0\n\nНативный инструмент для исследования памяти Mac. Все точки — реальные измерения. Данные остаются на устройстве.\n\nЧетыре режима\nCache Speed: последовательное чтение и поток NOP-кода. Последний — прокси выполнения инструкций, не прямая скорость I-cache. Read RAM и Write RAM: один поток NEON/SSE2, кэшируемая память. Latency: зависимые чтения в случайно перемешанном цикле, один узел на 128 байт; наносекунды на чтение, меньше — лучше. Задержка включает инструкцию загрузки, цикл, трансляцию адреса и планировщик. Это не чистая задержка DRAM.\n\nМетодика MBM-2.0\nБуфер выделяется, заполняется и прогревается до замера. Для Latency все узлы посещаются один раз за цикл, порядок детерминирован; отдельный массив перестановки не нужен. Быстрый: 15 мс × 3; баланс: 35 мс × 5; точный: 60 мс × 9 на точку. График показывает медиану и диапазон min–max. CV — стандартное отклонение / среднее × 100%; это описательный разброс, а не доверительный интервал.\n\nСравнение\nСохрани завершённый прогон как эталон и повтори тест с теми же настройками. Эталон сохраняется на диск отдельно для каждой вкладки. Пунктир — эталон; таблица показывает изменение скорости или задержки, положительный процент означает улучшение. При несовпадении методики, машины, режима или настроек сравнение отключается. Даже при одинаковых настройках фоновые процессы и нагрев могут менять результаты.\n\nУсловия\nmacOS сама выбирает ядро. Приложение не закрепляет поток за P-ядром и не выдумывает частоты или размеры кэша. Статус температуры и энергосбережения обновляется во время работы. Сильный нагрев и разброс CV > 5% отмечаются как повод повторить прогон, а не как диагноз.\n\nЭкспорт\nCSV и JSON содержат настройки, статус завершения, отдельные замеры, min/max, медиану и CV. В CSV у каждой строки есть единица измерения. iterations — число проходов буфера для GB/s или зависимых чтений для ns/load. Остановленный прогон можно экспортировать, но нельзя сделать эталоном.\n\nОграничения\nЭто не проверка исправности памяти, не многопоточный максимум и не тест GPU. Буфер данных ограничен 1 GiB и ⅛ RAM, код — 64 MiB. Готовый архив 1.0 в downloads не содержит версию 2.0: собери её через build.sh или используй артефакт успешной macOS-сборки.\n\nПодробности: README.md и VALIDATION.md.\n";
    v.aboutScroll.documentView=about;
    for (NSView *view in @[v.titleLabel,v.machineLabel,v.cacheLabel,v.tabs,v.rangeLabel,v.maximumPopup,v.profileLabel,v.profilePopup,v.chart,v.tableScroll,v.noteLabel,v.statusLabel,v.progress,v.startButton,v.exportButton,v.jsonButton,v.baselineButton,v.conditionLabel,v.aboutScroll]) [v addSubview:view];
    self.baselines=[NSMutableDictionary dictionary]; [self loadBaselines];
    self.conditionTimer=[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(updateConditions:) userInfo:nil repeats:YES];
    [self updateConditions:nil]; [self refreshResults];
    [self createMenu]; [v setNeedsLayout:YES]; [self.window center]; [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    if (self.smokeTest) {
        self.content.tabs.selectedSegment=3; [self changeTab:nil];
        [self.content.maximumPopup selectItemAtIndex:0]; [self.content.profilePopup selectItemAtIndex:0];
        [self startOrStop:nil];
    }
}
- (void)createMenu {
    NSMenu *bar=[[NSMenu alloc] init];
    NSMenuItem *appItem=[[NSMenuItem alloc] init]; [bar addItem:appItem];
    NSMenu *menu=[[NSMenu alloc] initWithTitle:@"Memory Benchmark"];
    [menu addItemWithTitle:@"О Memory Benchmark" action:@selector(showAbout:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Скрыть Memory Benchmark" action:@selector(hide:) keyEquivalent:@"h"];
    [menu addItemWithTitle:@"Завершить Memory Benchmark" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu=menu;
    NSMenuItem *editItem=[[NSMenuItem alloc] init]; [bar addItem:editItem];
    NSMenu *edit=[[NSMenu alloc] initWithTitle:@"Правка"];
    [edit addItemWithTitle:@"Копировать" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Выбрать всё" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu=edit; NSApp.mainMenu=bar;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return YES; }
- (void)applicationWillTerminate:(NSNotification *)note { (void)note; mb_cancel(self.context); }
- (void)showAbout:(id)sender { (void)sender; if (!self.running) { self.content.tabs.selectedSegment=4; [self changeTab:nil]; } }
- (void)changeTab:(id)sender {
    (void)sender; if (self.running) return;
    NSInteger mode=self.content.tabs.selectedSegment;
    self.content.showingAbout=mode==4; self.content.startButton.enabled=mode!=4;
    if (mode!=4) {
        self.selectedMode=mode; self.points=[self.resultsByMode[@(mode)] mutableCopy] ?: [NSMutableArray array];
        self.content.chart.points=self.points; self.content.chart.mode=mode;
        NSDictionary *meta=self.metadataByMode[@(mode)];
        self.content.chart.maximum=meta?[meta[@"maximum_bytes"] unsignedLongLongValue]:256*1024*1024;
        self.content.statusLabel.stringValue=meta?[NSString stringWithFormat:@"%@ · %@",meta[@"state"],meta[@"started"]]:@"Готов к тесту";
        [self refreshResults];
    }
    self.content.exportButton.enabled=mode!=4 && self.points.count>0;
    self.content.jsonButton.enabled=self.content.exportButton.enabled;
    if (mode==4) self.content.baselineButton.enabled=NO;
    [self.content setNeedsLayout:YES];
}
- (NSURL *)baselineURL:(NSInteger)mode {
    if (self.smokeTest) {
        NSURL *folder=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"MemoryLab-smoke-%d",NSProcessInfo.processInfo.processIdentifier]] isDirectory:YES];
        return [folder URLByAppendingPathComponent:[NSString stringWithFormat:@"baseline-%ld.json",(long)mode]];
    }
    NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [[support URLByAppendingPathComponent:@"MemoryBenchmark" isDirectory:YES] URLByAppendingPathComponent:[NSString stringWithFormat:@"baseline-%ld.json",(long)mode]];
}
- (void)loadBaselines {
    for (NSInteger mode=0;mode<4;++mode) {
        NSURL *url=[self baselineURL:mode]; if (!url) continue;
        NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
        if ([attributes fileSize]>2*1024*1024) continue;
        NSData *data=[NSData dataWithContentsOfURL:url];
        id report=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        if (MBValidReport(report)) self.baselines[@(mode)]=report;
    }
}
- (NSDictionary *)currentReport {
    NSMutableArray *records=[NSMutableArray array];
    for (MBPoint *p in self.points) [records addObject:MBPointRecord(p.result)];
    return @{@"schema_version":@2,@"metadata":[self.metadataByMode[@(self.selectedMode)] copy] ?: @{},@"points":records};
}
- (NSArray<MBPoint *> *)comparableBaseline {
    NSDictionary *report=self.baselines[@(self.selectedMode)];
    if (!MBComparable(self.metadataByMode[@(self.selectedMode)],report[@"metadata"])) return @[];
    NSMutableArray *points=[NSMutableArray array];
    for (id record in report[@"points"]) {
        mb_result result;
        if (MBDecodePoint(record,&result)) { MBPoint *p=[MBPoint new]; p.result=result; [points addObject:p]; }
    }
    return points;
}
- (NSNumber *)improvement:(mb_result)r {
    for (MBPoint *p in self.content.chart.baseline) {
        mb_result b=p.result;
        if (b.bytes==r.bytes && b.operation==r.operation) {
            double value=mb_result_value(&r), baseline=mb_result_value(&b);
            return @((r.operation==MB_LATENCY?(baseline-value)/baseline:value/baseline-1)*100);
        }
    }
    return nil;
}
- (void)saveBaseline:(id)sender {
    (void)sender; if (self.running) return;
    NSDictionary *report=[self currentReport]; if (!MBValidReport(report)) return;
    NSError *error=nil; NSURL *url=[self baselineURL:self.selectedMode];
    if (!url) { [self showError:@"Не удалось найти папку для эталона."]; return; }
    NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&error];
    if (!data || ![NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error] ||
        ![data writeToURL:url options:NSDataWritingAtomic error:&error]) { [self showError:error.localizedDescription ?: @"Не удалось сохранить эталон."]; return; }
    self.baselines[@(self.selectedMode)]=report; [self refreshResults];
    self.content.statusLabel.stringValue=@"Эталон сохранён · повтори тест с теми же настройками";
}
- (void)updateConditions:(NSTimer *)timer {
    (void)timer; NSProcessInfo *info=NSProcessInfo.processInfo;
    self.content.conditionLabel.stringValue=[NSString stringWithFormat:@"%@  ·  %@%@",info.lowPowerModeEnabled?@"Энергосбережение включено":@"Энергосбережение выключено",ThermalName(info.thermalState),SysNumber("sysctl.proc_translated")?@"  ·  Rosetta: рекомендуем нативную сборку":@""];
    self.content.conditionLabel.textColor=(info.lowPowerModeEnabled || info.thermalState>=NSProcessInfoThermalStateSerious)?NSColor.systemOrangeColor:NSColor.secondaryLabelColor;
    if (self.running) {
        NSMutableDictionary *meta=(NSMutableDictionary *)self.metadataByMode[@(self.selectedMode)];
        meta[@"thermal_peak"]=@(MAX([meta[@"thermal_peak"] integerValue],info.thermalState));
        if ([meta[@"low_power"] boolValue]!=info.lowPowerModeEnabled) meta[@"power_changed"]=@YES;
    }
}
- (void)refreshResults {
    self.content.chart.baseline=[self comparableBaseline];
    [self.content.chart setNeedsDisplay:YES]; [self.table reloadData];
    MBPoint *primary=nil;
    mb_operation operation=self.selectedMode==2?MB_WRITE:self.selectedMode==3?MB_LATENCY:MB_READ;
    NSUInteger noisy=0; double worstCV=0;
    for (MBPoint *p in self.points) {
        if (p.result.operation==(mb_operation)operation) primary=p;
        worstCV=fmax(worstCV,p.result.cv_percent); if (p.result.cv_percent>5) ++noisy;
    }
    mb_result r=primary?primary.result:(mb_result){0};
    self.content.stats[0].stringValue=primary?[NSString stringWithFormat:@"%.2f %s\n%@ рабочего набора",mb_result_value(&r),mb_operation_unit(r.operation),SizeLabel(r.bytes)]:@"Результат: —\nЗапусти измерение";
    self.content.stats[1].stringValue=self.points.count?[NSString stringWithFormat:@"Разброс до %.1f%% CV\n%lu точек · %u замеров на точку",worstCV,(unsigned long)self.points.count,r.samples]:@"Разброс: —\nКаждая точка — несколько замеров";
    NSNumber *change=primary?[self improvement:r]:nil;
    self.content.stats[2].stringValue=change?[NSString stringWithFormat:@"%+.1f%% к эталону\n%@ · %@",change.doubleValue,SizeLabel(r.bytes),r.operation==MB_LATENCY?@"снижение задержки":@"изменение скорости"]:self.baselines[@(self.selectedMode)]?@"Эталон сохранён\nДля сравнения нужны те же настройки":@"Эталон не выбран\nСохрани завершённый прогон";
    for (NSTextField *label in self.content.stats) label.font=[NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    NSMutableArray *notes=[NSMutableArray array];
    if (noisy) [notes addObject:[NSString stringWithFormat:@"%lu точек с CV > 5%%: попробуй точный режим и закрой фоновые задачи.",(unsigned long)noisy]];
    NSDictionary *meta=self.metadataByMode[@(self.selectedMode)];
    if ([meta[@"thermal_peak"] integerValue]>=NSProcessInfoThermalStateSerious) [notes addObject:@"Во время прогона macOS сообщала о сильном нагреве."];
    if ([meta[@"power_changed"] boolValue]) [notes addObject:@"Режим питания менялся во время теста."];
    [notes addObject:self.selectedMode==3?@"Зависимые случайные чтения · 128 байт между узлами · ns/load: меньше лучше.":@"Один поток · GB/s = 10⁹ байт/с · поток NOP-кода — прокси, не прямая скорость I-cache."];
    self.content.noteLabel.stringValue=[notes componentsJoinedByString:@" "];
    self.content.noteLabel.toolTip=self.content.noteLabel.stringValue;
    self.content.exportButton.enabled=!self.running && self.points.count>0;
    self.content.jsonButton.enabled=self.content.exportButton.enabled;
    self.content.baselineButton.enabled=!self.running && [meta[@"complete"] boolValue] && self.points.count>0;
}
- (void)startOrStop:(id)sender {
    (void)sender;
    if (self.running) { mb_cancel(self.context); self.content.startButton.enabled=NO; self.content.statusLabel.stringValue=@"Останавливаю…"; return; }
    const size_t maxima[]={64UL*1024*1024,256UL*1024*1024,512UL*1024*1024,1024UL*1024*1024};
    size_t maximum=maxima[self.content.maximumPopup.indexOfSelectedItem];
    if (maximum>NSProcessInfo.processInfo.physicalMemory/8) { [self showError:@"Выбери меньший буфер: лимит — ⅛ установленной памяти."]; return; }
    mb_context *ctx=mb_create(); if (!ctx) { [self showError:@"Не удалось создать измерительный контекст."]; return; }
    self.context=ctx; self.running=YES;
    self.points=[NSMutableArray array]; self.content.chart.points=self.points; self.content.chart.maximum=maximum;
    self.content.startButton.title=@"Стоп"; self.content.tabs.enabled=NO; self.content.maximumPopup.enabled=NO; self.content.profilePopup.enabled=NO; self.content.exportButton.enabled=NO; self.content.jsonButton.enabled=NO; self.content.baselineButton.enabled=NO;
    self.content.progress.doubleValue=0;
    NSInteger mode=self.selectedMode, profile=self.content.profilePopup.indexOfSelectedItem;
    const double durations[]={0.015,0.035,0.060}; const unsigned sampleCounts[]={3,5,9};
    double seconds=durations[profile]; unsigned samples=sampleCounts[profile];
    NSString *started=[NSISO8601DateFormatter.new stringFromDate:NSDate.date];
    NSMutableDictionary *metadata=[@{@"method":@(mb_method_version()),@"machine":self.content.machineLabel.stringValue,@"caches":self.content.cacheLabel.stringValue,@"started":started,@"mode":@[@"Cache Speed",@"Read RAM",@"Write RAM",@"Latency"][mode],@"maximum_bytes":@(maximum),@"seconds_per_sample":@(seconds),@"samples":@(samples),@"threads":@1,@"state":@"Выполняется",@"low_power":@(NSProcessInfo.processInfo.lowPowerModeEnabled),@"thermal_start":@(NSProcessInfo.processInfo.thermalState),@"thermal_peak":@(NSProcessInfo.processInfo.thermalState),@"complete":@NO,@"profile":@[@"quick",@"standard",@"precise"][profile],@"latency_stride_bytes":@(MB_LATENCY_STRIDE),@"order":@"ascending"} mutableCopy];
    self.metadataByMode[@(mode)]=metadata;
    self.activity=[NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated reason:@"Memory benchmark"];
    [self refreshResults];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        @autoreleasepool {
            size_t sizes[80],count=mb_sizes(maximum,sizes,80),completed=0,total=count;
            if (mode==0) for (size_t i=0;i<count;++i) if (sizes[i]<=64*1024*1024) ++total;
            NSString *failure=nil,*executionNote=nil; BOOL executeAvailable=YES;
            for (size_t i=0;i<count && !mb_is_cancelled(ctx) && !failure;++i) {
                int operation=mode==2?MB_WRITE:mode==3?MB_LATENCY:MB_READ;
                for (int j=0;j<(mode==0 && sizes[i]<=64*1024*1024?2:1);++j) {
                    int op=j==1?MB_EXECUTE:operation;
                    if (op==MB_EXECUTE && !executeAvailable) { ++completed; continue; }
                    mb_result result;
                    mb_status status=mb_measure(ctx,(mb_operation)op,sizes[i],seconds,samples,&result);
                    if (status==MB_CANCELLED) break;
                    if (status==MB_UNAVAILABLE && op==MB_EXECUTE) {
                        executeAvailable=NO; executionNote=[NSString stringWithUTF8String:mb_error(ctx)]; ++completed; continue;
                    }
                    if (status!=MB_OK) { failure=[NSString stringWithUTF8String:mb_error(ctx)]; break; }
                    MBPoint *point=[MBPoint new]; point.result=result; ++completed;
                    double progress=(double)completed/total;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.points addObject:point]; self.content.progress.doubleValue=progress;
                        self.content.statusLabel.stringValue=[NSString stringWithFormat:@"%@ · %@ · %.0f%%",op==MB_EXECUTE?@"Выполнение кода":op==MB_WRITE?@"Запись":op==MB_LATENCY?@"Задержка":@"Чтение",SizeLabel(result.bytes),progress*100];
                        [self refreshResults];
                    });
                }
            }
            BOOL cancelled=mb_is_cancelled(ctx);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.running=NO; self.context=NULL; mb_destroy(ctx);
                [NSProcessInfo.processInfo endActivity:self.activity]; self.activity=nil;
                self.content.startButton.title=@"Начать тест"; self.content.startButton.enabled=YES;
                self.content.tabs.enabled=YES; self.content.maximumPopup.enabled=YES; self.content.profilePopup.enabled=YES;
                NSString *state=failure?@"Ошибка · частичные результаты":cancelled?@"Остановлен · частичные результаты":executionNote?@"Готово · тест кода недоступен":@"Готово";
                metadata[@"state"]=state; metadata[@"complete"]=@(!cancelled && !failure && !executionNote);
                metadata[@"thermal_peak"]=@(MAX([metadata[@"thermal_peak"] integerValue],NSProcessInfo.processInfo.thermalState));
                if ([metadata[@"low_power"] boolValue]!=NSProcessInfo.processInfo.lowPowerModeEnabled) metadata[@"power_changed"]=@YES; metadata[@"thermal_end"]=@(NSProcessInfo.processInfo.thermalState);
                metadata[@"finished"]=[NSISO8601DateFormatter.new stringFromDate:NSDate.date];
                if (executionNote) metadata[@"execution_note"]=executionNote;
                if (failure) metadata[@"error"]=failure;
                self.content.statusLabel.stringValue=state;
                self.content.statusLabel.toolTip=executionNote ?: failure;
                if (!cancelled && !failure) self.content.progress.doubleValue=1;
                self.resultsByMode[@(mode)]=[self.points copy]; [self refreshResults];
                if (self.smokeTest) {
                    if (failure || cancelled || !self.points.count) exit(1);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{ [self finishSmokeTest]; });
                } else if (failure) [self showError:failure];
            });
        }
    });
}
- (void)writeSmokeScreenshot:(NSString *)path {
    [self.content layoutSubtreeIfNeeded]; [self.content display];
    NSBitmapImageRep *bitmap=[self.content bitmapImageRepForCachingDisplayInRect:self.content.bounds];
    [self.content cacheDisplayInRect:self.content.bounds toBitmapImageRep:bitmap];
    NSData *png=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (![png writeToFile:path atomically:YES]) exit(1);
}
- (void)finishSmokeTest {
    if (self.smokePass==0) {
        [self saveBaseline:nil];
        if (!self.baselines[@(self.selectedMode)]) exit(1);
        [self.baselines removeAllObjects]; [self loadBaselines];
        if ([self comparableBaseline].count!=self.points.count) exit(1);
        self.smokePass=1; [self startOrStop:nil]; return;
    }
    if (self.content.chart.baseline.count!=self.points.count) exit(1);
    NSString *path=NSProcessInfo.processInfo.environment[@"MB_SMOKE_SCREENSHOT"];
    if (path.length) {
        [self writeSmokeScreenshot:path];
        self.window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        [self.table reloadData]; [self.table.headerView setNeedsDisplay:YES];
        [self writeSmokeScreenshot:[[path stringByDeletingPathExtension] stringByAppendingString:@"-dark.png"]];
        NSDictionary *report=[self currentReport];
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
        if (![json writeToFile:[[path stringByDeletingPathExtension] stringByAppendingString:@".json"] atomically:YES]) exit(1);
        if (![MBCSV(report) writeToFile:[[path stringByDeletingPathExtension] stringByAppendingString:@".csv"] atomically:YES encoding:NSUTF8StringEncoding error:nil]) exit(1);
    }
    [NSFileManager.defaultManager removeItemAtURL:[self baselineURL:self.selectedMode].URLByDeletingLastPathComponent error:nil];
    [NSApp terminate:nil];
}
- (void)showError:(NSString *)message {
    NSAlert *alert=[NSAlert new]; alert.messageText=@"Memory Benchmark"; alert.informativeText=message;
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)view { (void)view; return self.points.count; }
- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)table; mb_result r=self.points[row].result; NSString *text=@"";
    switch (column.identifier.integerValue) {
        case 0: text=SizeLabel(r.bytes); break;
        case 1: text=@[@"Чтение",@"Запись",@"Выполнение кода*",@"Задержка"][r.operation]; break;
        case 2: text=[NSString stringWithFormat:@"%.3f %s",mb_result_value(&r),mb_operation_unit(r.operation)]; break;
        case 3: text=[NSString stringWithFormat:@"%.3f — %.3f",mb_result_minimum(&r),mb_result_maximum(&r)]; break;
        case 4: text=[NSString stringWithFormat:@"%.2f%@",r.cv_percent,r.cv_percent>5?@" ⚠":@""]; break;
        case 5: { NSNumber *change=[self improvement:r]; text=change?[NSString stringWithFormat:@"%+.1f%%",change.doubleValue]:@"—"; break; }
    }
    NSTextField *label=Label(text,11,NSFontWeightRegular,NSColor.labelColor);
    label.font=[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]; return label;
}
- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification; NSInteger row=self.table.selectedRow;
    self.content.chart.selectedBytes=(row>=0 && row<(NSInteger)self.points.count)?self.points[row].result.bytes:0;
    [self.content.chart setNeedsDisplay:YES];
}
- (void)exportCSV:(id)sender { (void)sender; [self exportReportJSON:NO]; }
- (void)exportJSON:(id)sender { (void)sender; [self exportReportJSON:YES]; }
- (void)exportReportJSON:(BOOL)json {
    if (self.running || !self.points.count) return;
    NSDictionary *report=[self currentReport];
    NSSavePanel *panel=[NSSavePanel savePanel];
    panel.nameFieldStringValue=json?@"memory-lab.json":@"memory-lab.csv";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response!=NSModalResponseOK) return;
        NSError *error=nil;
        NSData *data=json?[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&error]:[MBCSV(report) dataUsingEncoding:NSUTF8StringEncoding];
        if (!data || ![data writeToURL:panel.URL options:NSDataWritingAtomic error:&error]) [self showError:error.localizedDescription ?: @"Не удалось сохранить отчёт."];
    }];
}

@end

int main(int argc,const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        NSApplication *app=NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        __attribute__((objc_precise_lifetime)) MBApp *delegate=[MBApp new]; app.delegate=delegate;
        [app run];
    }
    return 0;
}

