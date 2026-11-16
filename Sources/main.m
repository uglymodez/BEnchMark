#import <Cocoa/Cocoa.h>
#include <sys/sysctl.h>
#include <math.h>
#include "benchmark.h"

static NSColor *ReadColor(void) { return [NSColor colorWithRed:1 green:0.85 blue:0.12 alpha:1]; }
static NSColor *WriteColor(void) { return [NSColor colorWithRed:0.28 green:0.77 blue:1 alpha:1]; }
static NSColor *ExecuteColor(void) { return [NSColor colorWithRed:0.27 green:0.95 blue:0.36 alpha:1]; }
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

@interface MBPoint : NSObject
@property mb_result result;
@end
@implementation MBPoint
@end

@interface MBChart : NSView
@property NSMutableArray<MBPoint *> *points;
@property NSInteger mode;
@property size_t maximum;
@end
@implementation MBChart
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self=[super initWithFrame:frame])) { _points=[NSMutableArray array]; _maximum=256*1024*1024; }
    return self;
}
- (void)text:(NSString *)s at:(NSPoint)p color:(NSColor *)color size:(CGFloat)size {
    [s drawAtPoint:p withAttributes:@{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular],NSForegroundColorAttributeName:color}];
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [[NSColor colorWithRed:0.025 green:0.055 blue:0.065 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:10 yRadius:10] fill];
    CGFloat w=self.bounds.size.width, h=self.bounds.size.height;
    NSRect plot=NSMakeRect(64,58,MAX(1,w-88),MAX(1,h-104));
    double high=10;
    for (MBPoint *p in self.points) high=fmax(high,p.result.gb_per_second*1.12);
    double magnitude=pow(10,floor(log10(high/5)));
    double step=ceil(high/5/magnitude)*magnitude;
    high=step*5;
    NSColor *grid=[NSColor colorWithRed:0.07 green:0.27 blue:0.28 alpha:1];
    NSColor *muted=[NSColor colorWithRed:0.51 green:0.66 blue:0.68 alpha:1];
    double maxLog=log2((double)self.maximum/4096.0);
    for (int j=0;j<=5;++j) {
        CGFloat y=plot.origin.y+plot.size.height*(1-j/5.0);
        NSBezierPath *line=[NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(plot.origin.x,y)]; [line lineToPoint:NSMakePoint(NSMaxX(plot),y)];
        [grid setStroke]; line.lineWidth=0.6; [line stroke];
        [self text:[NSString stringWithFormat:@"%5.0f",j*step] at:NSMakePoint(5,y-7) color:muted size:11];
    }
    int labelStride=MAX(1,(int)ceil((maxLog+1)*65/plot.size.width));
    for (int k=0;k<=maxLog;++k) {
        CGFloat x=plot.origin.x+plot.size.width*k/maxLog;
        NSBezierPath *line=[NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(x,plot.origin.y)]; [line lineToPoint:NSMakePoint(x,NSMaxY(plot))];
        [grid setStroke]; line.lineWidth=0.6; [line stroke];
        if (k%labelStride==0) {
            NSString *s=SizeLabel((uint64_t)4096<<k);
            [self text:s at:NSMakePoint(x-19,NSMaxY(plot)+10) color:muted size:10];
        }
    }
    [self text:@"GB/s" at:NSMakePoint(15,35) color:muted size:11];
    [self text:@"РАЗМЕР БУФЕРА · LOG₂" at:NSMakePoint(w-192,h-17) color:muted size:9];
    NSString *legend=self.mode==0?@"● Чтение данных":self.mode==1?@"● Read RAM":@"● Write RAM";
    [self text:legend at:NSMakePoint(20,16) color:self.mode==2?WriteColor():ReadColor() size:12];
    if (self.mode==0) [self text:@"● Выполнение кода*" at:NSMakePoint(220,16) color:ExecuteColor() size:12];
    for (int op=MB_READ;op<=MB_EXECUTE;++op) {
        NSColor *color=op==MB_READ?ReadColor():op==MB_WRITE?WriteColor():ExecuteColor();
        [color setStroke]; NSBezierPath *path=[NSBezierPath bezierPath]; path.lineWidth=2.2;
        BOOL first=YES;
        for (MBPoint *p in self.points) {
            mb_result r=p.result; if (r.operation!=(mb_operation)op) continue;
            CGFloat x=plot.origin.x+plot.size.width*log2((double)r.bytes/4096)/maxLog;
            CGFloat y=NSMaxY(plot)-plot.size.height*r.gb_per_second/high;
            NSPoint point=NSMakePoint(x,y);
            if (first) { [path moveToPoint:point]; first=NO; } else [path lineToPoint:point];
            [color setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x-1.5,y-1.5,3,3)] fill];
        }
        [path stroke];
    }
    if (!self.points.count) {
        NSString *message=@"Нажми «Начать тест» — график появится во время замеров";
        NSSize textSize=[message sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:14]}];
        [message drawAtPoint:NSMakePoint((w-textSize.width)/2,h/2) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:14],NSForegroundColorAttributeName:muted}];
    }
}
@end

@interface MBContent : NSView
@property NSTextField *titleLabel, *machineLabel, *cacheLabel, *rangeLabel, *profileLabel, *statusLabel, *noteLabel;
@property NSSegmentedControl *tabs;
@property NSPopUpButton *maximumPopup, *profilePopup;
@property NSButton *startButton, *exportButton;
@property NSProgressIndicator *progress;
@property MBChart *chart;
@property NSScrollView *tableScroll, *aboutScroll;
@property NSArray<NSTextField *> *stats;
@property BOOL showingAbout;
@end
@implementation MBContent
- (BOOL)isFlipped { return YES; }
- (void)layout {
    [super layout]; CGFloat w=self.bounds.size.width, h=self.bounds.size.height, gap=24;
    self.titleLabel.frame=NSMakeRect(gap,19,320,34);
    self.machineLabel.frame=NSMakeRect(gap,58,w-2*gap,21);
    self.cacheLabel.frame=NSMakeRect(gap,84,w-2*gap,18);
    self.tabs.frame=NSMakeRect(gap,118,460,28);
    self.rangeLabel.frame=NSMakeRect(w-413,121,65,22);
    self.maximumPopup.frame=NSMakeRect(w-348,115,112,32);
    self.profileLabel.frame=NSMakeRect(w-224,121,42,22);
    self.profilePopup.frame=NSMakeRect(w-181,115,157,32);
    CGFloat chartHeight=h-424;
    self.chart.frame=NSMakeRect(gap,162,w-2*gap,chartHeight);
    CGFloat y=162+chartHeight+14;
    for (NSUInteger i=0;i<self.stats.count;++i) self.stats[i].frame=NSMakeRect(gap+i*(w-2*gap)/3,y,(w-2*gap)/3-10,42);
    self.tableScroll.frame=NSMakeRect(gap,y+52,w-2*gap,106);
    self.noteLabel.frame=NSMakeRect(gap,h-82,w-2*gap,30);
    self.startButton.frame=NSMakeRect(w-178,h-47,154,30);
    self.exportButton.frame=NSMakeRect(w-315,h-47,126,30);
    self.progress.frame=NSMakeRect(gap,h-27,w-365,5);
    self.statusLabel.frame=NSMakeRect(gap,h-51,w-365,20);
    self.aboutScroll.frame=NSMakeRect(gap,162,w-2*gap,h-260);
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
@property BOOL running;
@property NSInteger selectedMode;
@property id activity;
@end

@implementation MBApp
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    self.points=[NSMutableArray array]; self.resultsByMode=[NSMutableDictionary dictionary]; self.metadataByMode=[NSMutableDictionary dictionary];
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1080,800) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"Memory Benchmark — Mac";
    self.window.minSize=NSMakeSize(1000,760); self.window.releasedWhenClosed=NO;
    self.window.backgroundColor=[NSColor colorWithWhite:0.96 alpha:1];
    self.window.appearance=[NSAppearance appearanceNamed:NSAppearanceNameAqua];
    self.content=[[MBContent alloc] initWithFrame:self.window.contentView.bounds];
    self.content.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    self.window.contentView=self.content; MBContent *v=self.content;
    NSColor *dark=[NSColor colorWithWhite:0.15 alpha:1], *muted=[NSColor secondaryLabelColor];
    v.titleLabel=Label(@"Memory benchmark",27,NSFontWeightSemibold,dark);
    NSString *cpu=SysString("machdep.cpu.brand_string"); if (!cpu.length) cpu=SysString("hw.model");
    NSString *translation=SysNumber("sysctl.proc_translated")?@" · Rosetta: пересобери под arm64":@" · native";
    v.machineLabel=Label([NSString stringWithFormat:@"%@  ·  %@ RAM  ·  %@%@  ·  macOS %@",cpu,SizeLabel(NSProcessInfo.processInfo.physicalMemory),[NSString stringWithUTF8String:mb_architecture()],translation,NSProcessInfo.processInfo.operatingSystemVersionString],12,NSFontWeightMedium,dark);
    v.machineLabel.toolTip=v.machineLabel.stringValue;
    v.cacheLabel=Label(CacheDescription(),11,NSFontWeightRegular,muted); v.cacheLabel.toolTip=[v.cacheLabel.stringValue stringByAppendingString:@". Сведения macOS; L2 может быть общим для группы ядер. Они не определяют, на каком ядре идёт тест."];
    v.tabs=[NSSegmentedControl segmentedControlWithLabels:@[@"Cache Speed",@"Read RAM",@"Write RAM",@"О программе"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeTab:)];
    v.tabs.selectedSegment=0;
    v.rangeLabel=Label(@"До",12,NSFontWeightRegular,muted);
    v.maximumPopup=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [v.maximumPopup addItemsWithTitles:@[@"64 MiB",@"256 MiB",@"512 MiB",@"1 GiB"]]; [v.maximumPopup selectItemAtIndex:1];
    v.profileLabel=Label(@"Тест",12,NSFontWeightRegular,muted);
    v.profilePopup=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [v.profilePopup addItemsWithTitles:@[@"Быстрый",@"Точный"]];
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
    NSArray *titles=@[@"Буфер",@"Операция",@"Медиана, GB/s",@"Мин. — макс., GB/s",@"Повторы"];
    for (NSUInteger i=0;i<titles.count;++i) {
        NSTableColumn *column=[[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%lu",(unsigned long)i]];
        column.title=titles[i]; column.width=i==1?230:180; [self.table addTableColumn:column];
    }
    v.tableScroll=[[NSScrollView alloc] initWithFrame:NSZeroRect]; v.tableScroll.documentView=self.table;
    v.tableScroll.hasVerticalScroller=YES; v.tableScroll.borderType=NSBezelBorder;
    v.noteLabel=Label(@"* Выполнение: объём NOP-кода / время; это не прямая скорость I-cache. Один поток, медиана 3 замеров. GB/s = 10⁹ байт/с.",11,NSFontWeightRegular,muted);
    v.noteLabel.maximumNumberOfLines=2; v.noteLabel.lineBreakMode=NSLineBreakByWordWrapping;
    v.statusLabel=Label(@"Готов к тесту · закрой тяжёлые приложения",12,NSFontWeightRegular,muted);
    v.progress=[[NSProgressIndicator alloc] initWithFrame:NSZeroRect]; v.progress.indeterminate=NO; v.progress.minValue=0; v.progress.maxValue=1;
    v.startButton=[NSButton buttonWithTitle:@"Начать тест" target:self action:@selector(startOrStop:)]; v.startButton.bezelStyle=NSBezelStyleRounded; v.startButton.keyEquivalent=@"\r";
    v.exportButton=[NSButton buttonWithTitle:@"Экспорт CSV" target:self action:@selector(exportCSV:)]; v.exportButton.bezelStyle=NSBezelStyleRounded; v.exportButton.enabled=NO;
    v.aboutScroll=[[NSScrollView alloc] initWithFrame:NSZeroRect]; v.aboutScroll.hasVerticalScroller=YES;
    NSTextView *about=[[NSTextView alloc] initWithFrame:NSMakeRect(0,0,960,650)]; about.editable=NO; about.selectable=YES;
    about.font=[NSFont systemFontOfSize:14]; about.backgroundColor=self.window.backgroundColor;
    about.textContainerInset=NSMakeSize(12,12); about.autoresizingMask=NSViewWidthSizable; about.textContainer.widthTracksTextView=YES;
    about.string=@"Memory Benchmark for Mac · 1.0\n\nНезависимый аналог по скриншоту старой Windows-программы. Оригинальное название версии и алгоритмы неизвестны. Результаты между программами напрямую не сравниваются.\n\nCache Speed\nЖёлтая линия — последовательное чтение данных, зелёная — выполнение блока NOP + RET. Размер растёт от 4 KiB до выбранного предела с четырьмя точками на удвоение. Выполнение ограничено 64 MiB. Зелёная линия — размер кода, делённый на время его прохождения; на неё влияют декодер, предвыборка, кэш микроопераций и другие части CPU. Это не измерение чистой пропускной способности I-cache.\n\nRead RAM / Write RAM\nПоследовательное чтение / обычная кэшируемая запись, 128-битные NEON (Apple Silicon) или SSE2 (Intel). Каждый проход обрабатывает весь буфер. Запись завершается барьером памяти. Это скорость данной нагрузки в одном потоке; не пиковая пропускная способность всех каналов памяти и не тест исправности RAM. Маленькие буферы обслуживаются кэшем. Даже большой буфер не гарантирует обход всех системных кэшей.\n\nМетодика MBM-1.0\nПамять выделяется и заполняется до замера; затем выполняется прогрев. Для каждой точки — 3 отдельных замера; на графике медиана. Быстрый режим: минимум 15 мс на замер, точный: 60 мс. Минимум и максимум доступны в таблице и CSV. Паузы планировщика и фоновые задачи входят в измеренное время.\n\nApple Silicon\nИспользуется один фоновый поток с QoS User Initiated. macOS выбирает ядро; закрепления за P-ядром нет. Размеры кэшей считываются через sysctl, неизвестные значения не выдумываются. Частота CPU не оценивается по времени выполнения. Сведения о кэшах не означают, что тест шёл на соответствующем ядре.\n\nДля сравнения результатов\nИспользуй одну версию программы, одинаковый режим, размер буфера и режим питания. Закрой фоновые тяжёлые приложения и дай Mac остыть. Для MacBook Air продолжительные тесты могут снижать частоту из-за нагрева.\n\nПриложение работает локально, без сети, дисковых тестов, прав администратора и внешних библиотек. «Стоп» сохраняет завершённые точки текущего прогона. При повторном запуске заменяются результаты только выбранной вкладки. CSV содержит настройки и состояние прогона.\n\nСборка и известные ограничения: README.md и VALIDATION.md в комплекте.\n";
    v.aboutScroll.documentView=about;
    for (NSView *view in @[v.titleLabel,v.machineLabel,v.cacheLabel,v.tabs,v.rangeLabel,v.maximumPopup,v.profileLabel,v.profilePopup,v.chart,v.tableScroll,v.noteLabel,v.statusLabel,v.progress,v.startButton,v.exportButton,v.aboutScroll]) [v addSubview:view];
    [self createMenu]; [v setNeedsLayout:YES]; [self.window center]; [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
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
- (void)showAbout:(id)sender { (void)sender; if (!self.running) { self.content.tabs.selectedSegment=3; [self changeTab:nil]; } }
- (void)changeTab:(id)sender {
    (void)sender; if (self.running) return;
    NSInteger mode=self.content.tabs.selectedSegment;
    self.content.showingAbout=mode==3; self.content.startButton.enabled=mode!=3;
    if (mode!=3) {
        self.selectedMode=mode; self.points=[self.resultsByMode[@(mode)] mutableCopy] ?: [NSMutableArray array];
        self.content.chart.points=self.points; self.content.chart.mode=mode;
        NSDictionary *meta=self.metadataByMode[@(mode)];
        self.content.chart.maximum=meta?[meta[@"maximum_bytes"] unsignedLongLongValue]:256*1024*1024;
        self.content.statusLabel.stringValue=meta?[NSString stringWithFormat:@"%@ · %@",meta[@"state"],meta[@"started"]]:@"Готов к тесту";
        [self refreshResults];
    }
    self.content.exportButton.enabled=mode!=3 && self.points.count>0;
    [self.content setNeedsLayout:YES];
}
- (void)refreshResults {
    [self.content.chart setNeedsDisplay:YES]; [self.table reloadData];
    MBPoint *read=nil,*write=nil,*execute=nil;
    for (MBPoint *p in self.points) {
        if (p.result.operation==MB_READ) read=p;
        else if (p.result.operation==MB_WRITE) write=p;
        else execute=p;
    }
    MBPoint *primary=self.selectedMode==2?write:read;
    self.content.stats[0].stringValue=primary?[NSString stringWithFormat:@"%@: %.2f GB/s",self.selectedMode==2?@"Запись":@"Чтение",primary.result.gb_per_second]:@"Скорость: —";
    self.content.stats[1].stringValue=execute?[NSString stringWithFormat:@"Выполнение*: %.2f GB/s\n%@ кода",execute.result.gb_per_second,SizeLabel(execute.result.bytes)]:self.selectedMode==0?@"Выполнение*: —":@"Один поток · 3 замера";
    self.content.stats[1].font=[NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    self.content.stats[2].stringValue=primary?[NSString stringWithFormat:@"Буфер: %@",SizeLabel(primary.result.bytes)]:@"Буфер: —";
    self.content.exportButton.enabled=!self.running && self.points.count>0;
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
    self.content.startButton.title=@"Стоп"; self.content.tabs.enabled=NO; self.content.maximumPopup.enabled=NO; self.content.profilePopup.enabled=NO; self.content.exportButton.enabled=NO;
    self.content.progress.doubleValue=0;
    NSInteger mode=self.selectedMode; double seconds=self.content.profilePopup.indexOfSelectedItem==0?0.015:0.060;
    NSString *started=[NSISO8601DateFormatter.new stringFromDate:NSDate.date];
    NSMutableDictionary *metadata=[@{@"method":@"MBM-1.0",@"machine":self.content.machineLabel.stringValue,@"caches":self.content.cacheLabel.stringValue,@"started":started,@"mode":@[@"Cache Speed",@"Read RAM",@"Write RAM"][mode],@"maximum_bytes":@(maximum),@"seconds_per_sample":@(seconds),@"samples":@3,@"threads":@1,@"state":@"Выполняется",@"low_power":@(NSProcessInfo.processInfo.lowPowerModeEnabled),@"thermal_start":@(NSProcessInfo.processInfo.thermalState)} mutableCopy];
    self.metadataByMode[@(mode)]=metadata;
    self.activity=[NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated reason:@"Memory benchmark"];
    [self refreshResults];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        @autoreleasepool {
            size_t sizes[80],count=mb_sizes(maximum,sizes,80),completed=0,total=count;
            if (mode==0) for (size_t i=0;i<count;++i) if (sizes[i]<=64*1024*1024) ++total;
            NSString *failure=nil,*executionNote=nil; BOOL executeAvailable=YES;
            for (size_t i=0;i<count && !mb_is_cancelled(ctx) && !failure;++i) {
                int operation=mode==2?MB_WRITE:MB_READ;
                for (int j=0;j<(mode==0 && sizes[i]<=64*1024*1024?2:1);++j) {
                    int op=j==1?MB_EXECUTE:operation;
                    if (op==MB_EXECUTE && !executeAvailable) { ++completed; continue; }
                    mb_result result;
                    mb_status status=mb_measure(ctx,(mb_operation)op,sizes[i],seconds,3,&result);
                    if (status==MB_CANCELLED) break;
                    if (status==MB_UNAVAILABLE && op==MB_EXECUTE) {
                        executeAvailable=NO; executionNote=[NSString stringWithUTF8String:mb_error(ctx)]; ++completed; continue;
                    }
                    if (status!=MB_OK) { failure=[NSString stringWithUTF8String:mb_error(ctx)]; break; }
                    MBPoint *point=[MBPoint new]; point.result=result; ++completed;
                    double progress=(double)completed/total;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.points addObject:point]; self.content.progress.doubleValue=progress;
                        self.content.statusLabel.stringValue=[NSString stringWithFormat:@"%@ · %@ · %.0f%%",op==MB_EXECUTE?@"Выполнение кода":op==MB_WRITE?@"Запись":@"Чтение",SizeLabel(result.bytes),progress*100];
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
                metadata[@"state"]=state; metadata[@"thermal_end"]=@(NSProcessInfo.processInfo.thermalState);
                metadata[@"finished"]=[NSISO8601DateFormatter.new stringFromDate:NSDate.date];
                if (executionNote) metadata[@"execution_note"]=executionNote;
                if (failure) metadata[@"error"]=failure;
                self.content.statusLabel.stringValue=state;
                self.content.statusLabel.toolTip=executionNote ?: failure;
                if (!cancelled && !failure) self.content.progress.doubleValue=1;
                self.resultsByMode[@(mode)]=[self.points copy]; [self refreshResults];
                if (failure) [self showError:failure];
            });
        }
    });
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
        case 1: text=@[@"Чтение",@"Запись",@"Выполнение кода*"][r.operation]; break;
        case 2: text=[NSString stringWithFormat:@"%.3f",r.gb_per_second]; break;
        case 3: text=[NSString stringWithFormat:@"%.3f — %.3f",r.minimum_gb_per_second,r.maximum_gb_per_second]; break;
        case 4: text=[NSString stringWithFormat:@"%llu",(unsigned long long)r.passes]; break;
    }
    NSTextField *label=Label(text,11,NSFontWeightRegular,NSColor.labelColor);
    label.font=[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]; return label;
}
- (void)exportCSV:(id)sender {
    (void)sender; if (self.running || !self.points.count) return;
    NSArray<MBPoint *> *points=[self.points copy]; NSDictionary *meta=[self.metadataByMode[@(self.selectedMode)] copy];
    NSSavePanel *panel=[NSSavePanel savePanel]; panel.nameFieldStringValue=@"memory-benchmark.csv";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response!=NSModalResponseOK) return;
        NSMutableString *csv=[NSMutableString stringWithString:@"# Memory Benchmark for Mac\n"];
        for (NSString *key in [[meta allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *value=[[meta[key] description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            [csv appendFormat:@"# %@: %@\n",key,value];
        }
        [csv appendString:@"operation,buffer_bytes,median_GB_s,min_GB_s,max_GB_s,sample_seconds,passes,samples\n"];
        for (MBPoint *p in points) {
            mb_result r=p.result;
            [csv appendFormat:@"%@,%zu,%.6f,%.6f,%.6f,%.9f,%llu,%u\n",@[@"read",@"write",@"execute_proxy"][r.operation],r.bytes,r.gb_per_second,r.minimum_gb_per_second,r.maximum_gb_per_second,r.seconds,(unsigned long long)r.passes,r.samples];
        }
        NSError *error=nil;
        if (![csv writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error]) [self showError:error.localizedDescription];
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
