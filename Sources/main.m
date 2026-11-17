#import <Cocoa/Cocoa.h>
#include <sys/sysctl.h>
#include <math.h>
#include "benchmark.h"
#import "report.h"

static NSColor *OperationColor(mb_operation op) {
    switch (op) {
        case MB_READ: return [NSColor colorWithRed:1 green:0.9 blue:0 alpha:1];
        case MB_WRITE: return [NSColor colorWithRed:0.15 green:1 blue:0.05 alpha:1];
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
@property size_t maximum, selectedBytes, pinnedBytes;
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
    if (self.mode==1 || self.mode==2) {
        self.selectedBytes=1024+256*(size_t)llround(fraction*40);
        [self setNeedsDisplay:YES]; return;
    }
    double target=log2(4096.0)+fraction*log2((double)self.maximum/4096);
    double nearest=INFINITY; self.selectedBytes=0;
    for (MBPoint *p in self.points) {
        double distance=fabs(log2((double)p.result.bytes)-target);
        if (distance<nearest) { nearest=distance; self.selectedBytes=p.result.bytes; }
    }
    [self setNeedsDisplay:YES];
}
- (void)mouseDown:(NSEvent *)event { [self mouseMoved:event]; self.pinnedBytes=self.selectedBytes; }
- (void)mouseExited:(NSEvent *)event { (void)event; self.selectedBytes=self.pinnedBytes; [self setNeedsDisplay:YES]; }
- (void)text:(NSString *)s at:(NSPoint)p color:(NSColor *)color size:(CGFloat)size {
    [s drawAtPoint:p withAttributes:@{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular],NSForegroundColorAttributeName:color}];
}
- (NSPoint)position:(mb_result)r value:(double)value plot:(NSRect)plot high:(double)high {
    return NSMakePoint(plot.origin.x+plot.size.width*log2((double)r.bytes/4096)/fmax(1,log2((double)self.maximum/4096)),NSMaxY(plot)-plot.size.height*value/high);
}
- (void)drawBlocks {
    [NSColor.blackColor setFill]; NSRectFill(self.bounds);
    CGFloat w=self.bounds.size.width,h=self.bounds.size.height;
    NSRect plot=NSMakeRect(64,76,w-88,h-120);
    NSColor *grid=self.mode==2?[NSColor colorWithRed:.4 green:.12 blue:.45 alpha:1]:[NSColor colorWithRed:0 green:.45 blue:.45 alpha:1];
    NSArray<NSColor *> *colors=@[NSColor.systemBlueColor,NSColor.cyanColor,NSColor.greenColor,NSColor.yellowColor];
    double high=1;
    for (NSArray *series in @[self.points,self.baseline ?: @[]]) for (MBPoint *p in series)
        { mb_result r=p.result; if (r.stride_bytes!=r.block_bytes) high=fmax(high,mb_result_maximum(&r)*1000*1.1); }
    for (int j=0;j<=10;++j) {
        CGFloat y=NSMaxY(plot)-plot.size.height*j/10;
        NSBezierPath *path=[NSBezierPath bezierPath]; [path moveToPoint:NSMakePoint(plot.origin.x,y)]; [path lineToPoint:NSMakePoint(NSMaxX(plot),y)];
        [grid setStroke]; path.lineWidth=.6; [path stroke];
        [self text:[NSString stringWithFormat:@"%.0f",high*j/10] at:NSMakePoint(4,y-6) color:NSColor.lightGrayColor size:10];
    }
    for (int i=0;i<=40;++i) {
        CGFloat x=plot.origin.x+plot.size.width*i/40;
        NSBezierPath *path=[NSBezierPath bezierPath]; [path moveToPoint:NSMakePoint(x,plot.origin.y)]; [path lineToPoint:NSMakePoint(x,NSMaxY(plot))];
        [grid setStroke]; path.lineWidth=.5; [path stroke];
        if (i%4==0) [self text:[NSString stringWithFormat:@"%d",i/4+1] at:NSMakePoint(x-8,NSMaxY(plot)+9) color:NSColor.lightGrayColor size:11];
    }
    CGFloat dash[]={3,4};
    [self text:self.mode==1?@"ЧТЕНИЕ БЛОКА":@"ЗАПИСЬ БЛОКА" at:NSMakePoint(18,16) color:NSColor.whiteColor size:12];
    [self text:@"MB/s" at:NSMakePoint(8,57) color:NSColor.lightGrayColor size:10];
    [self text:@"ФАКТИЧЕСКИЙ ШАГ ДОСТУПА · KiB" at:NSMakePoint(w-295,h-17) color:NSColor.lightGrayColor size:10];
    NSMutableArray *hover=[NSMutableArray array];
    for (NSUInteger b=0;b<4;++b) {
        size_t block=32UL<<b; NSColor *color=colors[b];
        [self text:[NSString stringWithFormat:@"● %zu Б",block] at:NSMakePoint(225+b*95,16) color:color size:12];
        for (NSUInteger pass=0;pass<2;++pass) {
            NSBezierPath *path=[NSBezierPath bezierPath]; BOOL first=YES;
            NSArray *series=pass?self.points:(self.baseline ?: @[]);
            for (MBPoint *p in series) {
                mb_result r=p.result; if (r.block_bytes!=block || r.stride_bytes==block) continue;
                double mean=mb_result_mean(&r)*1000;
                NSPoint point=NSMakePoint(plot.origin.x+plot.size.width*(r.stride_bytes-1024)/10240.,NSMaxY(plot)-plot.size.height*mean/high);
                if (first) { [path moveToPoint:point]; first=NO; } else [path lineToPoint:point];
                if (pass) {
                    CGFloat top=NSMaxY(plot)-plot.size.height*r.maximum_gb_per_second*1000/high;
                    CGFloat bottom=NSMaxY(plot)-plot.size.height*r.minimum_gb_per_second*1000/high;
                    NSBezierPath *whisker=[NSBezierPath bezierPath]; [whisker moveToPoint:NSMakePoint(point.x,top)]; [whisker lineToPoint:NSMakePoint(point.x,bottom)];
                    [[color colorWithAlphaComponent:.3] setStroke]; whisker.lineWidth=.7; [whisker stroke];
                    [((r.cv_percent>5 || fabs(mb_result_drift_percent(&r))>10)?NSColor.orangeColor:color) setStroke];
                    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(point.x-2,point.y-2,4,4)] stroke];
                }
                if (pass && self.selectedBytes==r.stride_bytes) [hover addObject:[NSString stringWithFormat:@"%zu Б: %.0f",block,mean]];
            }
            if (!pass) [path setLineDash:dash count:2 phase:0];
            [[color colorWithAlphaComponent:pass?1:.4] setStroke]; path.lineWidth=pass?1.8:1; [path stroke];
        }
    }
    NSString *detail=self.selectedBytes?[NSString stringWithFormat:@"Шаг %zu Б · %@ MB/s",self.selectedBytes,[hover componentsJoinedByString:@" / "]]:@"Точки — замеры · штрихи — min–max · оранжевый ободок — CV > 5% / изменение > 10%";
    [self text:detail at:NSMakePoint(18,40) color:NSColor.lightGrayColor size:10];
    if (!self.points.count) [self text:@"Начни тест для сравнения блоков 32 / 64 / 128 / 256 байт" at:NSMakePoint(90,h/2) color:NSColor.lightGrayColor size:12];
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    if (self.mode==1 || self.mode==2) { [self drawBlocks]; return; }
    [NSColor.blackColor setFill]; NSRectFill(self.bounds);
    CGFloat w=self.bounds.size.width, h=self.bounds.size.height;
    NSRect plot=NSMakeRect(64,76,MAX(1,w-88),MAX(1,h-120));
    double high=1;
    for (NSArray *series in @[self.points,self.baseline ?: @[]])
        for (MBPoint *p in series) { mb_result r=p.result; high=fmax(high,(series==self.points?mb_result_maximum(&r):(self.mode==0?mb_result_mean(&r):mb_result_value(&r)))*1.12); }
    double magnitude=pow(10,floor(log10(high/5))), step=ceil(high/5/magnitude)*magnitude; high=step*5;
    NSColor *grid=[NSColor colorWithRed:0 green:0.55 blue:0.55 alpha:1], *muted=[NSColor colorWithWhite:0.8 alpha:1];
    double maxLog=fmax(1,log2((double)self.maximum/4096));
    for (int j=0;j<=20;++j) {
        CGFloat y=plot.origin.y+plot.size.height*(1-j/20.0);
        NSBezierPath *line=[NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(plot.origin.x,y)]; [line lineToPoint:NSMakePoint(NSMaxX(plot),y)];
        [[grid colorWithAlphaComponent:j%2==0?0.85:0.45] setStroke]; line.lineWidth=j%2==0?0.8:0.5; [line stroke];
        if (j%2==0) [self text:[NSString stringWithFormat:@"%5.1f",j*step/4] at:NSMakePoint(5,y-7) color:muted size:10];
    }
    int labelStride=MAX(1,(int)ceil((maxLog+1)*65/plot.size.width));
    for (int k=0;k<=maxLog*4;++k) {
        CGFloat x=plot.origin.x+plot.size.width*k/(maxLog*4);
        NSBezierPath *line=[NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(x,plot.origin.y)]; [line lineToPoint:NSMakePoint(x,NSMaxY(plot))];
        [[grid colorWithAlphaComponent:k%4==0?0.85:0.45] setStroke]; line.lineWidth=k%4==0?0.8:0.5; [line stroke];
        if (k%(4*labelStride)==0) [self text:SizeLabel((uint64_t)4096<<(k/4)) at:NSMakePoint(x-19,NSMaxY(plot)+10) color:muted size:10];
    }
    [self text:self.mode==3?@"ns/load":@"GB/s" at:NSMakePoint(12,57) color:muted size:10];
    [self text:@"РАБОЧИЙ НАБОР · LOG₂" at:NSMakePoint(w-192,h-17) color:muted size:9];
    NSString *legend=@[@"● ЧТЕНИЕ · СРЕДНЕЕ",@"● ЧТЕНИЕ ПАМЯТИ",@"● ЗАПИСЬ ПАМЯТИ",@"● ЗАДЕРЖКА · МЕНЬШЕ ЛУЧШЕ"][self.mode];
    [self text:legend at:NSMakePoint(20,16) color:OperationColor(self.mode==2?MB_WRITE:self.mode==3?MB_LATENCY:MB_READ) size:12];
    if (self.mode==0) [self text:@"● ЗАПИСЬ · СРЕДНЕЕ" at:NSMakePoint(240,16) color:OperationColor(MB_WRITE) size:12];
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
            [band closePath]; [[color colorWithAlphaComponent:0.08] setFill]; [band fill];
        }
        for (NSUInteger pass=0;pass<2;++pass) {
            NSArray *series=pass==0?(self.baseline ?: @[]):current;
            NSBezierPath *path=[NSBezierPath bezierPath]; path.lineWidth=pass==0?1.4:2.3;
            if (!pass) { CGFloat dash[]={5,5}; [path setLineDash:dash count:2 phase:0]; }
            [[color colorWithAlphaComponent:pass==0?0.45:1] setStroke]; BOOL first=YES;
            for (MBPoint *p in series) {
                mb_result r=p.result; if (r.operation!=(mb_operation)op) continue;
                NSPoint point=[self position:r value:(self.mode==0?mb_result_mean(&r):mb_result_value(&r)) plot:plot high:high];
                if (first) { [path moveToPoint:point]; first=NO; } else [path lineToPoint:point];
                if (pass) { [((r.cv_percent>5 || fabs(mb_result_drift_percent(&r))>10)?NSColor.orangeColor:color) setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(point.x-1.5,point.y-1.5,3,3)] fill]; }
            }
            [path stroke];
        }
    }
    if (self.selectedBytes) {
        NSMutableArray *details=[NSMutableArray arrayWithObject:SizeLabel(self.selectedBytes)];
        for (MBPoint *p in self.points) if (p.result.bytes==self.selectedBytes) {
            mb_result r=p.result;
            [details addObject:[NSString stringWithFormat:@"%s %.2f %s · CV %.1f%%",mb_operation_name(r.operation),(self.mode==0?mb_result_mean(&r):mb_result_value(&r)),mb_operation_unit(r.operation),r.cv_percent]];
            NSPoint point=[self position:r value:(self.mode==0?mb_result_mean(&r):mb_result_value(&r)) plot:plot high:high];
            [OperationColor(r.operation) setStroke]; NSBezierPath *ring=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(point.x-5,point.y-5,10,10)]; [ring stroke];
        }
        [self text:[details componentsJoinedByString:@"  /  "] at:NSMakePoint(20,40) color:NSColor.whiteColor size:11];
    } else [self text:@"Точки — замеры · без сглаживания · щёлкни точку → «Исходные замеры»" at:NSMakePoint(20,40) color:muted size:10];
    if (!self.points.count) {
        [self text:@"Начни тест, чтобы увидеть профиль памяти своего Mac" at:NSMakePoint(MAX(70,(w-455)/2),h/2) color:muted size:13];
    }
}
@end

@interface MBContent : NSView
@property NSTextField *titleLabel, *machineLabel, *cacheLabel, *rangeLabel, *profileLabel, *statusLabel, *noteLabel, *conditionLabel;
@property NSSegmentedControl *tabs;
@property NSPopUpButton *maximumPopup, *profilePopup;
@property NSButton *startButton, *exportButton, *jsonButton, *baselineButton, *auditButton, *baselineToggle;
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
    CGFloat chartHeight=h-528;
    self.chart.frame=NSMakeRect(gap,184,w-2*gap,chartHeight);
    CGFloat y=184+chartHeight+14;
    for (NSUInteger i=0;i<self.stats.count;++i) self.stats[i].frame=NSMakeRect(gap+i*(w-2*gap)/3,y,(w-2*gap)/3-10,42);
    self.tableScroll.frame=NSMakeRect(gap,y+52,w-2*gap,160);
    self.noteLabel.frame=NSMakeRect(gap,h-110,w-2*gap,32);
    self.startButton.frame=NSMakeRect(w-178,h-47,154,30);
    self.baselineButton.frame=NSMakeRect(gap,h-47,192,30);
    self.exportButton.frame=NSMakeRect(gap+204,h-47,120,30);
    self.auditButton.frame=NSMakeRect(gap+468,h-47,175,30);
    self.baselineToggle.frame=NSMakeRect(gap+650,h-44,140,24);
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
@property NSWindow *window, *auditWindow;
@property MBContent *content;
@property NSTableView *table;
@property NSArray<NSDictionary *> *rangeRows, *blockRows;
@property NSMutableArray<MBPoint *> *points;
@property NSMutableDictionary<NSNumber *,NSArray<MBPoint *> *> *resultsByMode;
@property NSMutableDictionary<NSNumber *,NSDictionary *> *metadataByMode;
@property mb_context *context;
@property BOOL running, smokeTest;
@property NSUInteger smokePass;
@property NSInteger selectedMode, runningMode;
@property BOOL smokeNavigated;
@property id activity;
@property NSMutableDictionary<NSNumber *, NSDictionary *> *baselines;
@property NSTimer *conditionTimer;
@end

@implementation MBApp
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    self.smokeTest=[NSProcessInfo.processInfo.arguments containsObject:@"--smoke-test"];
    self.points=[NSMutableArray array]; self.resultsByMode=[NSMutableDictionary dictionary]; self.metadataByMode=[NSMutableDictionary dictionary];
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1080,880) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"Memory Benchmark — Mac";
    self.window.minSize=NSMakeSize(1000,800); self.window.releasedWhenClosed=NO;
    self.window.backgroundColor=NSColor.windowBackgroundColor;
    self.content=[[MBContent alloc] initWithFrame:self.window.contentView.bounds];
    self.content.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    self.window.contentView=self.content; MBContent *v=self.content;
    NSColor *dark=NSColor.labelColor, *muted=[NSColor secondaryLabelColor];
    v.titleLabel=Label(@"Memory Lab  /  2.5",27,NSFontWeightSemibold,dark);
    NSString *cpu=SysString("machdep.cpu.brand_string"); if (!cpu.length) cpu=SysString("hw.model");
    NSString *translation=SysNumber("sysctl.proc_translated")?@" · Rosetta: пересобери под arm64":@" · native";
    v.machineLabel=Label([NSString stringWithFormat:@"%@  ·  %@ RAM  ·  %@%@  ·  macOS %@",cpu,SizeLabel(NSProcessInfo.processInfo.physicalMemory),[NSString stringWithUTF8String:mb_architecture()],translation,NSProcessInfo.processInfo.operatingSystemVersionString],12,NSFontWeightMedium,dark);
    v.machineLabel.toolTip=v.machineLabel.stringValue;
    v.cacheLabel=Label(CacheDescription(),11,NSFontWeightRegular,muted); v.cacheLabel.toolTip=[v.cacheLabel.stringValue stringByAppendingString:@". Сведения macOS; L2 может быть общим для группы ядер. Они не определяют, на каком ядре идёт тест."];
    v.tabs=[NSSegmentedControl segmentedControlWithLabels:@[@"5 диапазонов",@"Read RAM",@"Write RAM",@"Latency",@"О программе"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeTab:)];
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
    for (NSString *s in @[@"Чтение: —",@"Запись: —",@"Размер буфера: —"]) {
        NSTextField *label=Label(s,16,NSFontWeightMedium,dark); label.maximumNumberOfLines=2;
        [stats addObject:label]; [v addSubview:label];
    }
    v.stats=stats;
    self.table=[[NSTableView alloc] initWithFrame:NSZeroRect]; self.table.dataSource=self; self.table.delegate=self;
    self.table.usesAlternatingRowBackgroundColors=YES; self.table.rowHeight=24;
    self.table.columnAutoresizingStyle=NSTableViewUniformColumnAutoresizingStyle;
    [self configureTable];
    v.tableScroll=[[NSScrollView alloc] initWithFrame:NSZeroRect]; v.tableScroll.documentView=self.table;
    v.tableScroll.hasVerticalScroller=YES; v.tableScroll.borderType=NSBezelBorder;
    v.noteLabel=Label(@"Пять размеров буфера · чтение и запись · GB/s",11,NSFontWeightRegular,muted);
    v.noteLabel.maximumNumberOfLines=2; v.noteLabel.lineBreakMode=NSLineBreakByWordWrapping;
    v.statusLabel=Label(@"Готов к тесту · закрой тяжёлые приложения",12,NSFontWeightRegular,muted);
    v.progress=[[NSProgressIndicator alloc] initWithFrame:NSZeroRect]; v.progress.indeterminate=NO; v.progress.minValue=0; v.progress.maxValue=1;
    v.startButton=[NSButton buttonWithTitle:@"Начать тест" target:self action:@selector(startOrStop:)]; v.startButton.bezelStyle=NSBezelStyleRounded; v.startButton.keyEquivalent=@"\r";
    v.exportButton=[NSButton buttonWithTitle:@"Экспорт CSV" target:self action:@selector(exportCSV:)]; v.exportButton.bezelStyle=NSBezelStyleRounded; v.exportButton.enabled=NO;
    v.jsonButton=[NSButton buttonWithTitle:@"Экспорт JSON" target:self action:@selector(exportJSON:)]; v.jsonButton.bezelStyle=NSBezelStyleRounded; v.jsonButton.enabled=NO;
    v.baselineButton=[NSButton buttonWithTitle:@"Сохранить как эталон" target:self action:@selector(saveBaseline:)]; v.baselineButton.bezelStyle=NSBezelStyleRounded; v.baselineButton.enabled=NO;
    v.auditButton=[NSButton buttonWithTitle:@"Исходные замеры" target:self action:@selector(showAudit:)]; v.auditButton.bezelStyle=NSBezelStyleRounded; v.auditButton.enabled=NO;
    v.auditButton.toolTip=@"Щёлкни точку графика, затем открой время и число проходов каждого повтора. Без выбора показана последняя точка.";
    v.baselineToggle=[NSButton checkboxWithTitle:@"Показать эталон" target:self action:@selector(toggleBaseline:)];
    v.baselineToggle.state=NSControlStateValueOff;
    v.baselineButton.toolTip=@"Сохранить завершённый прогон этой вкладки для сравнения. Эталон остаётся после перезапуска приложения.";
    v.conditionLabel=Label(@"",11,NSFontWeightMedium,muted);
    v.aboutScroll=[[NSScrollView alloc] initWithFrame:NSZeroRect]; v.aboutScroll.hasVerticalScroller=YES;
    NSTextView *about=[[NSTextView alloc] initWithFrame:NSMakeRect(0,0,960,650)]; about.editable=NO; about.selectable=YES;
    about.font=[NSFont systemFontOfSize:14]; about.backgroundColor=self.window.backgroundColor;
    about.textContainerInset=NSMakeSize(12,12); about.autoresizingMask=NSViewWidthSizable; about.textContainer.widthTracksTextView=YES;
    about.string=@"Memory Lab · 2.5\n\nПять диапазонов\nПодробный график: 16 интервалов на удвоение размера, 225–289 размеров буфера. Пять строк таблицы: 4 KiB, 64 KiB, 1 MiB, 16 MiB и выбранный максимум (64 MiB – 1 GiB). Это опорные размеры рабочего набора, а не пять физических уровней кэша. Чтение и запись измеряются отдельно в одном потоке. На графике все промежуточные замеры; линии соединяют соседние значения без сглаживания или искусственных ступеней. Форма зависит от Mac, нагрузки и режима питания. График показывает среднее арифметическое, полоса — минимум и максимум повторов. Все скорости — GB/s (10⁹ байт/с).\n\nОтносительная скорость\nСредняя скорость / самая высокая средняя скорость этой же операции среди пяти строк таблицы в завершённом прогоне × 100%. Для чтения и записи свой максимум. 100% — самый быстрый диапазон; это не доля попаданий в кэш и не процент от теоретической скорости процессора. При остановке теста проценты не рассчитываются.\n\nДругие режимы\nRead RAM и Write RAM: четыре блока 32/64/128/256 байт. В фиксированном буфере меняется шаг между началами блоков: 1–11 KiB, 41 значение. Ось X — фактический шаг 1–11 KiB. Каждая точка — среднее реальных повторов; вертикальный штрих — min–max, оранжевая отметка — CV > 5% или изменение внутри серии > 10%. Считаются только полезные байты, не пропуски. Таблица: min/max повторов всех шагов, среднее средних по 41 шагу, отдельный линейный проход с шагом равным блоку. Эффективность = среднее / линейный × 100%, может превышать 100%. Это наша описанная методика, не восстановленный алгоритм старой программы. Latency измеряет зависимые случайные чтения, один узел на 128 байт; ns/load, меньше — лучше. В Latency график показывает медиану и min–max; в Read/Write RAM — средние. Это не чистая задержка DRAM. Тест NOP-кода остаётся доступен через CLI.\n\nМетодика MBM-2.0\nБуфер выделяется и заполняется; затем та же нагрузка выполняется 100–300 мс до измеряемой серии (быстрый: 100 мс, баланс: 210 мс, точный: 300 мс). Прогрев записывается отдельно и не входит в скорость. Это снижает влияние старта, но не гарантирует стабильность. Быстрый: 15 мс × 3; баланс: 35 мс × 5; точный: 60 мс × 9 на операцию и размер. Подробный тест занимает от минуты до восьми минут на измерения и прогрев, плюс подготовка. CV — стандартное отклонение / среднее × 100%, описательный разброс. macOS выбирает ядро; приложение не закрепляет поток за P-ядром. Размеры кэша вверху — сведения macOS.\n\nЭталон и экспорт\nСохрани завершённый прогон и повтори тест с теми же настройками: пунктир покажет эталон. В пяти диапазонах пунктир также показывает средние, а проценты таблицы сравнивают диапазоны текущего прогона. В Latency таблица показывает изменение к эталону. В Read/Write RAM пунктир — эталон, эффективность относится к линейному замеру текущего прогона. Эталоны Cache Speed и редкого прогона 2.1 несовместимы с подробным графиком 2.2. CSV и JSON сохраняют исходные повторы, статистики и относительные скорости; JSON также содержит сводку пяти диапазонов. Незавершённый прогон можно экспортировать, но нельзя сохранить как эталон.\n\nУсловия и ограничения\nФоновые задачи, нагрев и энергосбережение влияют на результаты. CV > 5% или изменение между первой и последней половинами серии более 10% — повод проверить условия. Средний повтор нечётной серии не входит в этот показатель изменения. Все повторы остаются в среднем, значения не отбрасываются. Рост ns/load означает ухудшение задержки. Эталон 2.4 несовместим с протоколом 2.5. Это не проверка исправности памяти, не многопоточный максимум и не тест GPU. Лимит буфера — 1 GiB и ⅛ RAM. Результаты остаются на устройстве.\n\nПроверка происхождения данных\nЩёлкни точку графика → «Исходные замеры»: время, число проходов и расчёт скорости каждого повтора. Те же данные записываются в JSON/CSV; при загрузке формула проверяется. Перерисовка завершается между точками, до следующего таймера. Эталон скрыт по умолчанию и включается явно. Внешние процессы, планировщик и нагрев остаются источниками разброса. Это скорость подсистемы памяти при данной нагрузке, а не общая мощность Mac.\n\nПодробности: README.md и VALIDATION.md.\n";
    v.aboutScroll.documentView=about;
    for (NSView *view in @[v.titleLabel,v.machineLabel,v.cacheLabel,v.tabs,v.rangeLabel,v.maximumPopup,v.profileLabel,v.profilePopup,v.chart,v.tableScroll,v.noteLabel,v.statusLabel,v.progress,v.startButton,v.exportButton,v.jsonButton,v.baselineButton,v.auditButton,v.baselineToggle,v.conditionLabel,v.aboutScroll]) [v addSubview:view];
    self.baselines=[NSMutableDictionary dictionary]; [self loadBaselines];
    self.conditionTimer=[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(updateConditions:) userInfo:nil repeats:YES];
    [self updateConditions:nil]; [self refreshResults];
    [self createMenu]; [v setNeedsLayout:YES]; [self.window center]; [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    if (self.smokeTest) {
        NSString *smokeMode=NSProcessInfo.processInfo.environment[@"MB_SMOKE_MODE"];
        self.content.tabs.selectedSegment=[smokeMode isEqual:@"ranges"]?0:[smokeMode isEqual:@"read"]?1:[smokeMode isEqual:@"write"]?2:3; [self changeTab:nil];
        [self.content.maximumPopup selectItemAtIndex:0]; [self.content.profilePopup selectItemAtIndex:0];
        [self startOrStop:nil];
    }
}
- (void)configureTable {
    NSArray *titles=self.selectedMode==0?@[@"Буфер",@"Чт. мин",@"Чт. сред.",@"Чт. макс.",@"Чт. %",@"Зап. мин",@"Зап. сред.",@"Зап. макс.",@"Зап. %"]:((self.selectedMode==1 || self.selectedMode==2)?@[@"Блок",@"Мин. MB/s",@"Макс. MB/s",@"Сред. MB/s",@"Линейн. MB/s",@"Эффект. %"]:@[@"Буфер",@"Операция",@"Медиана",@"Мин. — макс.",@"CV, %",@"К эталону"]);
    self.table.dataSource=nil;
    [self.table deselectAll:nil];
    for (NSTableColumn *column in self.table.tableColumns.copy) [self.table removeTableColumn:column];
    for (NSUInteger i=0;i<titles.count;++i) {
        NSTableColumn *column=[[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%lu",(unsigned long)i]];
        column.headerCell=[[MBHeaderCell alloc] initTextCell:titles[i]]; column.title=titles[i];
        column.width=self.selectedMode==0?108:(i==1?190:150); column.minWidth=70;
        column.headerToolTip=self.selectedMode==0?(i==4 || i==8?@"Среднее / самое быстрое среднее той же операции среди 5 строк × 100%. Только после полного прогона.":@"Скорость в GB/s. Среднее арифметическое, минимум и максимум повторов."):@"Статистика измерений";
        [self.table addTableColumn:column];
    }
    self.table.dataSource=self;
    [self.table reloadData];
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
- (void)showAbout:(id)sender { (void)sender; self.content.tabs.selectedSegment=4; [self changeTab:nil]; }
- (void)changeTab:(id)sender {
    (void)sender;
    NSInteger mode=self.content.tabs.selectedSegment;
    self.content.showingAbout=mode==4; self.content.startButton.enabled=self.running || mode!=4;
    if (mode!=4) {
        self.table.dataSource=nil; [self.table deselectAll:nil];
        self.selectedMode=mode; self.points=(self.running && mode==self.runningMode)?(NSMutableArray *)self.resultsByMode[@(mode)]:([self.resultsByMode[@(mode)] mutableCopy] ?: [NSMutableArray array]);
        self.rangeRows=@[]; self.blockRows=@[];
        [self configureTable];
        self.content.chart.points=self.points; self.content.chart.mode=mode; self.content.chart.selectedBytes=0; self.content.chart.pinnedBytes=0;
        NSDictionary *meta=self.metadataByMode[@(mode)];
        self.content.chart.maximum=meta?[meta[@"maximum_bytes"] unsignedLongLongValue]:256*1024*1024;
        self.content.statusLabel.stringValue=meta?[NSString stringWithFormat:@"%@ · %@",meta[@"state"],meta[@"started"]]:@"Готов к тесту";
        [self refreshResults];
    }
    self.content.exportButton.enabled=!self.running && mode!=4 && self.points.count>0;
    self.content.jsonButton.enabled=self.content.exportButton.enabled;
    self.content.auditButton.enabled=self.content.exportButton.enabled;
    if (mode==4) { self.content.baselineButton.enabled=NO; self.content.auditButton.enabled=NO; }
    if (self.running) self.content.statusLabel.stringValue=[NSString stringWithFormat:@"Выполняется %@ · можно смотреть вкладки; «Стоп» остановит тест",@[@"5 диапазонов",@"Read RAM",@"Write RAM",@"Latency"][self.runningMode]];
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
    NSMutableDictionary *report=[@{@"schema_version":@2,@"metadata":[self.metadataByMode[@(self.selectedMode)] copy] ?: @{},@"points":records} mutableCopy];
    if (self.selectedMode==0) report[@"range_summary"]=MBRangeSummary(report);
    if (self.selectedMode==1 || self.selectedMode==2) report[@"block_summary"]=MBBlockSummary(report);
    return report;
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
            double value=self.selectedMode==0?mb_result_mean(&r):mb_result_value(&r), baseline=self.selectedMode==0?mb_result_mean(&b):mb_result_value(&b);
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
    self.baselines[@(self.selectedMode)]=report; self.content.baselineToggle.state=NSControlStateValueOn; [self refreshResults];
    self.content.statusLabel.stringValue=@"Эталон сохранён · повтори тест с теми же настройками";
}
- (void)updateConditions:(NSTimer *)timer {
    (void)timer; NSProcessInfo *info=NSProcessInfo.processInfo;
    self.content.conditionLabel.stringValue=[NSString stringWithFormat:@"%@  ·  %@%@",info.lowPowerModeEnabled?@"Энергосбережение включено":@"Энергосбережение выключено",ThermalName(info.thermalState),SysNumber("sysctl.proc_translated")?@"  ·  Rosetta: рекомендуем нативную сборку":@""];
    self.content.conditionLabel.textColor=(info.lowPowerModeEnabled || info.thermalState>=NSProcessInfoThermalStateSerious)?NSColor.systemOrangeColor:NSColor.secondaryLabelColor;
    if (self.running) {
        NSMutableDictionary *meta=(NSMutableDictionary *)self.metadataByMode[@(self.runningMode)];
        meta[@"thermal_peak"]=@(MAX([meta[@"thermal_peak"] integerValue],info.thermalState));
        if ([meta[@"low_power"] boolValue]!=info.lowPowerModeEnabled) meta[@"power_changed"]=@YES;
    }
}
- (void)refreshResults {
    if (self.selectedMode==1 || self.selectedMode==2) {
        NSDictionary *report=[self currentReport];
        if (![report[@"metadata"] count]) report=@{@"metadata":@{@"sweep":@"block-stride-v1"},@"points":@[]};
        self.blockRows=MBBlockSummary(report);
    }
    if (self.selectedMode==0) {
        NSDictionary *report=[self currentReport];
        if (![report[@"metadata"] count]) report=@{@"metadata":@{@"mode":@"Memory Ranges",@"maximum_bytes":@(self.content.chart.maximum)},@"points":@[]};
        self.rangeRows=MBRangeSummary(report);
    }
    self.content.chart.baseline=self.content.baselineToggle.state==NSControlStateValueOn?[self comparableBaseline]:@[];
    [self.content.chart setNeedsDisplay:YES]; [self.table reloadData];
    MBPoint *primary=nil;
    mb_operation operation=self.selectedMode==2?MB_WRITE:self.selectedMode==3?MB_LATENCY:MB_READ;
    NSUInteger noisy=0,drifting=0; double worstCV=0;
    for (MBPoint *p in self.points) {
        if (p.result.operation==(mb_operation)operation) primary=p;
        mb_result sample=p.result; if (fabs(mb_result_drift_percent(&sample))>10) ++drifting;
        worstCV=fmax(worstCV,p.result.cv_percent); if (p.result.cv_percent>5) ++noisy;
    }
    mb_result r=primary?primary.result:(mb_result){0};
    self.content.stats[0].stringValue=primary?[NSString stringWithFormat:@"%.2f %s\n%@ рабочего набора",mb_result_value(&r),mb_operation_unit(r.operation),SizeLabel(r.bytes)]:@"Результат: —\nЗапусти измерение";
    self.content.stats[1].stringValue=self.points.count?[NSString stringWithFormat:@"Разброс до %.1f%% CV\n%lu точек · %u замеров на точку",worstCV,(unsigned long)self.points.count,r.samples]:@"Разброс: —\nКаждая точка — несколько замеров";
    NSNumber *change=primary?[self improvement:r]:nil;
    self.content.stats[2].stringValue=change?[NSString stringWithFormat:@"%+.1f%% к эталону\n%@ · %@",change.doubleValue,SizeLabel(r.bytes),r.operation==MB_LATENCY?@"снижение задержки":@"изменение скорости"]:self.baselines[@(self.selectedMode)]?@"Эталон сохранён\nДля сравнения нужны те же настройки":@"Эталон не выбран\nСохрани завершённый прогон";
    if (self.selectedMode==0) {
        for (NSUInteger op=0;op<2;++op) {
            double best=0;
            for (NSDictionary *row in self.rangeRows) best=fmax(best,[row[op==0?@"read":@"write"][@"mean"] doubleValue]);
            self.content.stats[op].stringValue=best>0?[NSString stringWithFormat:@"%@: %.2f GB/s\nЛучшее среднее из 5 строк",op==0?@"Чтение":@"Запись",best]:[NSString stringWithFormat:@"%@: —",op==0?@"Чтение":@"Запись"];
        }
        size_t chartSizes[MB_PROFILE_CAPACITY];
        size_t expected=2*mb_profile_sizes(self.content.chart.maximum,chartSizes,MB_PROFILE_CAPACITY);
        self.content.stats[2].stringValue=MBValidReport([self currentReport])?[NSString stringWithFormat:@"%lu размеров · 5 строк\n100%% = лучшее среднее из 5 строк",(unsigned long)self.points.count/2]:[NSString stringWithFormat:@"%lu / %zu измерений\nПроценты — после полного теста",(unsigned long)self.points.count,expected];
    }
    if (self.selectedMode==1 || self.selectedMode==2) {
        self.content.stats[0].stringValue=@"32 / 64 / 128 / 256 байт\nЧетыре серии, один поток";
        self.content.stats[1].stringValue=@"Фактический шаг 1–11 KiB\nТочки и разброс реальных замеров";
        self.content.stats[2].stringValue=@"Эффект. = среднее / линейн.\nОтдельный последовательный замер";
    }
    for (NSTextField *label in self.content.stats) label.font=[NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    NSMutableArray *notes=[NSMutableArray array];
    if (drifting) [notes addObject:[NSString stringWithFormat:@"%lu точек: изменение внутри серии > 10%%. Подробности — «Исходные замеры».",(unsigned long)drifting]];
    if (noisy) [notes addObject:[NSString stringWithFormat:@"%lu точек с CV > 5%%.",(unsigned long)noisy]];
    NSDictionary *meta=self.metadataByMode[@(self.selectedMode)];
    if ([meta[@"thermal_peak"] integerValue]>=NSProcessInfoThermalStateSerious) [notes addObject:@"Во время прогона macOS сообщала о сильном нагреве."];
    if ([meta[@"power_changed"] boolValue]) [notes addObject:@"Режим питания менялся во время теста."];
    [notes addObject:self.selectedMode==3?@"Зависимые случайные чтения · 128 байт между узлами · ns/load: меньше лучше.":self.selectedMode==0?@"Подробный график; таблица — 5 размеров, не уровни кэша. GB/s; % — относительно лучшей из 5 строк той же операции.":@"MB/s = 10⁶ байт/с; считаются полезные байты блоков. Эффект. может быть >100%. Методика Mac, не точная копия старого теста."];
    self.content.noteLabel.stringValue=[notes componentsJoinedByString:@" "];
    self.content.noteLabel.toolTip=self.content.noteLabel.stringValue;
    self.content.exportButton.enabled=!self.running && !self.content.showingAbout && self.points.count>0;
    self.content.jsonButton.enabled=self.content.exportButton.enabled;
    self.content.auditButton.enabled=self.content.exportButton.enabled;
    self.content.baselineButton.enabled=!self.running && !self.content.showingAbout && [meta[@"complete"] boolValue] && self.points.count>0;
}
- (void)startOrStop:(id)sender {
    (void)sender;
    if (self.running) { mb_cancel(self.context); self.content.startButton.enabled=NO; self.content.statusLabel.stringValue=@"Останавливаю…"; return; }
    if (self.content.showingAbout) return;
    const size_t maxima[]={64UL*1024*1024,256UL*1024*1024,512UL*1024*1024,1024UL*1024*1024};
    size_t maximum=maxima[self.content.maximumPopup.indexOfSelectedItem];
    if (maximum>NSProcessInfo.processInfo.physicalMemory/8) { [self showError:@"Выбери меньший буфер: лимит — ⅛ установленной памяти."]; return; }
    mb_context *ctx=mb_create(); if (!ctx) { [self showError:@"Не удалось создать измерительный контекст."]; return; }
    self.context=ctx; self.running=YES; self.runningMode=self.selectedMode;
    self.points=[NSMutableArray array]; self.content.chart.points=self.points; self.content.chart.maximum=maximum;
    self.content.startButton.title=@"Стоп"; self.content.tabs.enabled=YES; self.content.maximumPopup.enabled=NO; self.content.profilePopup.enabled=NO; self.content.exportButton.enabled=NO; self.content.jsonButton.enabled=NO; self.content.baselineButton.enabled=NO;
    self.content.progress.doubleValue=0; self.content.auditButton.enabled=NO; self.content.chart.selectedBytes=0; self.content.chart.pinnedBytes=0;
    NSInteger mode=self.selectedMode, profile=self.content.profilePopup.indexOfSelectedItem;
    const double durations[]={0.015,0.035,0.060}; const unsigned sampleCounts[]={3,5,9};
    double seconds=durations[profile]; unsigned samples=sampleCounts[profile];
    NSString *started=[NSISO8601DateFormatter.new stringFromDate:NSDate.date];
    NSMutableDictionary *metadata=[@{@"method":@(mb_method_version()),@"machine":self.content.machineLabel.stringValue,@"caches":self.content.cacheLabel.stringValue,@"started":started,@"mode":@[@"Memory Ranges",@"Read RAM",@"Write RAM",@"Latency"][mode],@"maximum_bytes":@(maximum),@"seconds_per_sample":@(seconds),@"samples":@(samples),@"threads":@1,@"state":@"Выполняется",@"low_power":@(NSProcessInfo.processInfo.lowPowerModeEnabled),@"thermal_start":@(NSProcessInfo.processInfo.thermalState),@"thermal_peak":@(NSProcessInfo.processInfo.thermalState),@"complete":@NO,@"profile":@[@"quick",@"standard",@"precise"][profile],@"latency_stride_bytes":@(MB_LATENCY_STRIDE),@"order":@"ascending"} mutableCopy];
    metadata[@"measurement_protocol"]=@"timing-warmup-v2"; metadata[@"run_id"]=NSUUID.UUID.UUIDString;
    metadata[@"warmup_policy"]=@"same-workload-clamp-6x-100-300ms";
    metadata[@"chart_smoothing"]=@"none"; metadata[@"chart_value"]=mode==3?@"median":@"mean";
    if (mode==0) metadata[@"sweep"]=@"dense-16-v1";
    if (mode==1 || mode==2) metadata[@"sweep"]=@"block-stride-v1";
    self.metadataByMode[@(mode)]=metadata;
    NSMutableArray<MBPoint *> *runPoints=self.points;
    self.resultsByMode[@(mode)]=runPoints;
    self.activity=[NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated reason:@"Memory benchmark"];
    [self refreshResults];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        @autoreleasepool {
            size_t sizes[MB_PROFILE_CAPACITY],count=mode==0?mb_profile_sizes(maximum,sizes,MB_PROFILE_CAPACITY):mb_sizes(maximum,sizes,MB_PROFILE_CAPACITY),completed=0,total=count*(mode==0?2:1);
            BOOL blocks=mode==1 || mode==2;
            if (blocks) { count=4*(MB_BLOCK_STEPS+1); total=count; }
            NSString *failure=nil;
            for (size_t i=0;i<count && !mb_is_cancelled(ctx) && !failure;++i) {
                int operation=mode==2?MB_WRITE:mode==3?MB_LATENCY:MB_READ;
                for (int j=0;j<(mode==0?2:1);++j) {
                    int op=j==1?MB_WRITE:operation;
                    mb_result result;
                    size_t block=blocks?(32UL<<(i/(MB_BLOCK_STEPS+1))):0;
                    size_t step=blocks?i%(MB_BLOCK_STEPS+1):0;
                    size_t stride=step?1024+(step-1)*256:block;
                    mb_status status=blocks?mb_measure_blocks(ctx,(mb_operation)op,maximum,block,stride,seconds,samples,&result):mb_measure(ctx,(mb_operation)op,sizes[i],seconds,samples,&result);
                    if (status==MB_CANCELLED) break;
                    if (status!=MB_OK) { failure=[NSString stringWithUTF8String:mb_error(ctx)]; break; }
                    MBPoint *point=[MBPoint new]; point.result=result; ++completed;
                    double progress=(double)completed/total;
                    // Finish heavy report/table/chart updates before timing the next point.
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        [runPoints addObject:point]; self.content.progress.doubleValue=progress;
                        if (self.selectedMode!=mode || self.content.showingAbout) return;
                        self.content.statusLabel.stringValue=[NSString stringWithFormat:@"%@ · %@ · %.0f%%",op==MB_EXECUTE?@"Выполнение кода":op==MB_WRITE?@"Запись":op==MB_LATENCY?@"Задержка":@"Чтение",SizeLabel(result.bytes),progress*100];
                        [self refreshResults]; [self.content displayIfNeeded];
                        if (self.smokeTest && !self.smokeNavigated) { self.smokeNavigated=YES; [self smokeNavigation]; }
                    });
                }
            }
            BOOL cancelled=mb_is_cancelled(ctx);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.running=NO; self.context=NULL; mb_destroy(ctx);
                [NSProcessInfo.processInfo endActivity:self.activity]; self.activity=nil;
                self.content.startButton.title=@"Начать тест"; self.content.startButton.enabled=!self.content.showingAbout;
                self.content.tabs.enabled=YES; self.content.maximumPopup.enabled=YES; self.content.profilePopup.enabled=YES;
                NSString *state=failure?@"Ошибка · частичные результаты":cancelled?@"Остановлен · частичные результаты":@"Готово";
                metadata[@"state"]=state; metadata[@"complete"]=@(!cancelled && !failure && completed==total);
                metadata[@"thermal_peak"]=@(MAX([metadata[@"thermal_peak"] integerValue],NSProcessInfo.processInfo.thermalState));
                if ([metadata[@"low_power"] boolValue]!=NSProcessInfo.processInfo.lowPowerModeEnabled) metadata[@"power_changed"]=@YES; metadata[@"thermal_end"]=@(NSProcessInfo.processInfo.thermalState);
                metadata[@"finished"]=[NSISO8601DateFormatter.new stringFromDate:NSDate.date];
                if (failure) metadata[@"error"]=failure;
                self.content.statusLabel.stringValue=[NSString stringWithFormat:@"%@: %@",metadata[@"mode"],state];
                self.content.statusLabel.toolTip=failure;
                if (!cancelled && !failure) self.content.progress.doubleValue=1;
                self.resultsByMode[@(mode)]=[runPoints copy]; [self refreshResults];
                if (self.smokeTest) {
                    if (self.smokePass==2) {
                        if (!cancelled || failure || [metadata[@"complete"] boolValue] || !self.content.tabs.enabled) exit(1);
                        [self smokeNavigation];
                        [NSFileManager.defaultManager removeItemAtURL:[self baselineURL:mode].URLByDeletingLastPathComponent error:nil];
                        [NSApp terminate:nil]; return;
                    }
                    if (failure || cancelled || !runPoints.count) exit(1);
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
- (void)smokeNavigation {
    NSInteger original=self.content.tabs.selectedSegment;
    for (NSNumber *tab in @[@1,@2,@3,@4,@0,@4,@2,@1,@0]) {
        self.content.tabs.selectedSegment=tab.integerValue;
        [NSApp sendAction:self.content.tabs.action to:self.content.tabs.target from:self.content.tabs];
        [self.content layoutSubtreeIfNeeded]; [self.table reloadData]; [self.content display];
        if (!self.content.tabs.enabled || self.content.showingAbout!=(tab.integerValue==4)) exit(1);
        if (tab.integerValue!=4 && self.selectedMode!=tab.integerValue) exit(1);
    }
    self.content.tabs.selectedSegment=original; [self changeTab:nil];
}
- (void)finishSmokeTest {
    [self smokeNavigation];
    if (self.selectedMode==1 || self.selectedMode==2) {
        if (!MBValidReport([self currentReport]) || self.points.count!=168 || self.table.numberOfRows!=4) exit(1);
        for (NSDictionary *row in self.blockRows) if (!row[@"efficiency_percent"]) exit(1);
    }
    if (self.selectedMode==0) {
        size_t sizes[MB_PROFILE_CAPACITY];
        size_t expected=2*mb_profile_sizes(self.content.chart.maximum,sizes,MB_PROFILE_CAPACITY);
        if (self.table.numberOfRows!=5 || self.table.tableColumns.count!=9 || self.points.count!=expected || expected<=10 || !MBValidReport([self currentReport])) exit(1);
        for (NSString *op in @[@"read",@"write"]) {
            double best=0;
            for (NSDictionary *row in self.rangeRows) {
                NSNumber *percent=row[op][@"relative_speed_percent"];
                if (!percent || percent.doubleValue<=0 || percent.doubleValue>100) exit(1);
                best=fmax(best,percent.doubleValue);
            }
            if (fabs(best-100)>1e-9) exit(1);
        }
    }
    if (self.smokePass==0) {
        NSString *path=NSProcessInfo.processInfo.environment[@"MB_SMOKE_SCREENSHOT"];
        NSData *first=[NSJSONSerialization dataWithJSONObject:[self currentReport] options:NSJSONWritingPrettyPrinted error:nil];
        if (path.length && ![first writeToFile:[[path stringByDeletingPathExtension] stringByAppendingString:@"-first.json"] atomically:YES]) exit(1);
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
        for (NSDictionary *record in report[@"points"]) {
            mb_result r; if (!MBDecodePoint(record,&r) || !r.work_units_per_iteration) exit(1);
        }
        [self showAudit:nil];
        NSString *audit=MBTimingDescription([self selectedAuditReport]);
        if (![audit writeToFile:[[path stringByDeletingPathExtension] stringByAppendingString:@"-samples.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil]) exit(1);
        [self.auditWindow close];
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
        if (![json writeToFile:[[path stringByDeletingPathExtension] stringByAppendingString:@".json"] atomically:YES]) exit(1);
        if (![MBCSV(report) writeToFile:[[path stringByDeletingPathExtension] stringByAppendingString:@".csv"] atomically:YES encoding:NSUTF8StringEncoding error:nil]) exit(1);
    }
    // Cancel a third run from About; navigation and Stop must remain available.
    self.smokePass=2; [self startOrStop:nil];
    self.content.tabs.selectedSegment=4; [self changeTab:nil];
    if (!self.content.startButton.enabled) exit(1);
    [NSApp sendAction:self.content.startButton.action to:self.content.startButton.target from:self.content.startButton];
}
- (void)showError:(NSString *)message {
    NSAlert *alert=[NSAlert new]; alert.messageText=@"Memory Benchmark"; alert.informativeText=message;
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)view { (void)view; return self.selectedMode==0?self.rangeRows.count:(self.selectedMode==1 || self.selectedMode==2)?self.blockRows.count:self.points.count; }
- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)table;
    if (self.selectedMode==1 || self.selectedMode==2) {
        if (row<0 || row>=(NSInteger)self.blockRows.count) return nil;
        NSDictionary *record=self.blockRows[row]; NSInteger col=column.identifier.integerValue;
        NSString *text=[NSString stringWithFormat:@"%@ байт",record[@"block_bytes"]];
        if (col>0 && col<6) {
            NSNumber *value=record[@[@"minimum",@"maximum",@"mean",@"linear",@"efficiency_percent"][col-1]];
            text=value?[NSString stringWithFormat:col==5?@"%.1f%%":@"%.0f",value.doubleValue*(col==5?1:1000)]:@"—";
        }
        return Label(text,12,NSFontWeightRegular,NSColor.labelColor);
    }
    if (self.selectedMode==0) {
        if (row<0 || row>=(NSInteger)self.rangeRows.count) return nil;
        NSDictionary *range=self.rangeRows[row]; NSInteger col=column.identifier.integerValue;
        NSString *text=SizeLabel([range[@"buffer_bytes"] unsignedLongLongValue]);
        if (col>0) {
            NSDictionary *value=range[col<5?@"read":@"write"];
            NSString *key=@[@"minimum",@"mean",@"maximum",@"relative_speed_percent"][(col-1)%4];
            NSNumber *number=value[key];
            text=number?[NSString stringWithFormat:(col==4 || col==8)?@"%.1f%%":@"%.3f",number.doubleValue]:@"—";
        }
        NSTextField *label=Label(text,11,NSFontWeightRegular,NSColor.labelColor);
        label.font=[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]; return label;
    }
    if (row<0 || row>=(NSInteger)self.points.count) return nil;
    mb_result r=self.points[row].result; NSString *text=@"";
    switch (column.identifier.integerValue) {
        case 0: text=SizeLabel(r.bytes); break;
        case 1: text=@[@"Чтение",@"Запись",@"Выполнение кода*",@"Задержка"][r.operation]; break;
        case 2: text=[NSString stringWithFormat:@"%.3f %s",mb_result_value(&r),mb_operation_unit(r.operation)]; break;
        case 3: text=[NSString stringWithFormat:@"%.3f — %.3f",mb_result_minimum(&r),mb_result_maximum(&r)]; break;
        case 4: text=[NSString stringWithFormat:@"%.2f%@",r.cv_percent,(r.cv_percent>5 || fabs(mb_result_drift_percent(&r))>10)?@" ⚠":@""]; break;
        case 5: { NSNumber *change=[self improvement:r]; text=change?[NSString stringWithFormat:@"%+.1f%%",change.doubleValue]:@"—"; break; }
    }
    NSTextField *label=Label(text,11,NSFontWeightRegular,NSColor.labelColor);
    label.font=[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]; return label;
}
- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification; NSInteger row=self.table.selectedRow;
    if (self.selectedMode==1 || self.selectedMode==2) { self.content.chart.selectedBytes=0; self.content.chart.pinnedBytes=0; return; }
    self.content.chart.selectedBytes=self.selectedMode==0?
        ((row>=0 && row<(NSInteger)self.rangeRows.count)?[self.rangeRows[row][@"buffer_bytes"] unsignedLongLongValue]:0):
        ((row>=0 && row<(NSInteger)self.points.count)?self.points[row].result.bytes:0);
    self.content.chart.pinnedBytes=self.content.chart.selectedBytes;
    [self.content.chart setNeedsDisplay:YES];
}
- (void)toggleBaseline:(id)sender { (void)sender; [self refreshResults]; }
- (NSDictionary *)selectedAuditReport {
    NSMutableDictionary *report=[[self currentReport] mutableCopy];
    MBPoint *last=self.points.lastObject; if (!last) return report;
    BOOL blocks=self.selectedMode==1 || self.selectedMode==2;
    size_t selected=self.content.chart.selectedBytes ?: (blocks?last.result.stride_bytes:last.result.bytes);
    NSMutableArray *records=[NSMutableArray array];
    for (MBPoint *p in self.points) {
        mb_result r=p.result;
        if ((blocks?r.stride_bytes:r.bytes)==selected) [records addObject:MBPointRecord(r)];
    }
    report[@"points"]=records; return report;
}
- (void)showAudit:(id)sender {
    (void)sender; if (self.running || !self.points.count) return;
    if (!self.auditWindow) {
        self.auditWindow=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,880,570) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        self.auditWindow.releasedWhenClosed=NO; self.auditWindow.title=@"Memory Lab — исходные замеры";
    }
    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:self.auditWindow.contentView.bounds];
    scroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable; scroll.hasVerticalScroller=YES;
    NSTextView *text=[[NSTextView alloc] initWithFrame:scroll.bounds]; text.editable=NO;
    text.font=[NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular]; text.textContainerInset=NSMakeSize(16,16);
    text.autoresizingMask=NSViewWidthSizable; text.textContainer.widthTracksTextView=YES;
    text.string=MBTimingDescription([self selectedAuditReport]); scroll.documentView=text;
    self.auditWindow.contentView=scroll; [self.auditWindow center]; [self.auditWindow makeKeyAndOrderFront:nil];
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


