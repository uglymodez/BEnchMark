#import <Cocoa/Cocoa.h>
#include <sys/sysctl.h>
#include <math.h>
#include <execinfo.h>
#include <unistd.h>
#include "benchmark.h"
#import "report.h"

static NSColor *OperationColor(mb_operation op) {
    switch (op) {
        case MB_READ: return [NSColor colorWithRed:1 green:0.9 blue:0 alpha:1];
        case MB_WRITE: return [NSColor colorWithRed:0.15 green:1 blue:0.05 alpha:1];
        case MB_EXECUTE: return [NSColor colorWithRed:0.2 green:1 blue:0.25 alpha:1];
        case MB_LATENCY: return [NSColor colorWithRed:0.77 green:0.59 blue:1 alpha:1];
    }
    return NSColor.labelColor;
}
static BOOL BlockMode(NSInteger mode) { return mode==6 || mode==7; }
static BOOL SummaryMode(NSInteger mode) { return mode==0 || mode==5; }
static NSString *ModeName(NSInteger mode) {
    return @[@"Memory Ranges",@"Read RAM",@"Write RAM",@"Latency",@"About",@"Cache Profile",@"Read Blocks",@"Write Blocks"][mode];
}
static NSColor *BlockColor(unsigned block) {
    switch (block) {
        case 32: return [NSColor colorWithRed:0.16 green:0.62 blue:1 alpha:1];
        case 64: return [NSColor colorWithRed:0.2 green:0.9 blue:0.95 alpha:1];
        case 128: return [NSColor colorWithRed:0.3 green:0.95 blue:0.32 alpha:1];
        default: return [NSColor colorWithRed:1 green:0.9 blue:0.12 alpha:1];
    }
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
@property NSInteger selectedGap;
@property unsigned selectedBlock;
@property NSTrackingArea *tracking;
@end
@implementation MBChart
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self=[super initWithFrame:frame])) { _points=[NSMutableArray array]; _maximum=256*1024*1024; _selectedGap=NSIntegerMax; }
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
    if (BlockMode(self.mode)) {
        double target=-3072+fmax(0,fmin(1,(mouse.x-64)/MAX(1,self.bounds.size.width-88)))*10240;
        double nearest=INFINITY; self.selectedGap=NSIntegerMax;
        for (MBPoint *p in self.points) if (fabs(p.result.access_gap_bytes-target)<nearest) {
            nearest=fabs(p.result.access_gap_bytes-target); self.selectedGap=p.result.access_gap_bytes;
        }
        [self setNeedsDisplay:YES]; return;
    }
    double fraction=fmax(0,fmin(1,(mouse.x-64)/MAX(1,self.bounds.size.width-88)));
    double target=log2(4096.0)+fraction*log2((double)self.maximum/4096);
    double nearest=INFINITY; self.selectedBytes=0;
    for (MBPoint *p in self.points) {
        double distance=fabs(log2((double)p.result.bytes)-target);
        if (distance<nearest) { nearest=distance; self.selectedBytes=p.result.bytes; }
    }
    [self setNeedsDisplay:YES];
}
- (void)mouseExited:(NSEvent *)event { (void)event; self.selectedBytes=0; self.selectedGap=NSIntegerMax; [self setNeedsDisplay:YES]; }
- (void)text:(NSString *)s at:(NSPoint)p color:(NSColor *)color size:(CGFloat)size {
    [s drawAtPoint:p withAttributes:@{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular],NSForegroundColorAttributeName:color}];
}
- (NSPoint)position:(mb_result)r value:(double)value plot:(NSRect)plot high:(double)high {
    return NSMakePoint(plot.origin.x+plot.size.width*log2((double)r.bytes/4096)/fmax(1,log2((double)self.maximum/4096)),NSMaxY(plot)-plot.size.height*value/high);
}
- (NSPoint)blockPosition:(mb_result)r value:(double)value plot:(NSRect)plot high:(double)high {
    return NSMakePoint(plot.origin.x+plot.size.width*(r.access_gap_bytes+3072)/10240.0,NSMaxY(plot)-plot.size.height*value/high);
}
- (void)drawBlockChart {
    [NSColor.blackColor setFill]; NSRectFill(self.bounds);
    CGFloat w=self.bounds.size.width,h=self.bounds.size.height;
    NSRect plot=NSMakeRect(64,76,MAX(1,w-88),MAX(1,h-120));
    NSColor *muted=[NSColor colorWithWhite:0.8 alpha:1];
    NSColor *grid=self.mode==7?[NSColor colorWithRed:0.5 green:0.17 blue:0.45 alpha:1]:[NSColor colorWithRed:0 green:0.5 blue:0.5 alpha:1];
    double high=1;
    for (NSArray *series in @[self.points,self.baseline ?: @[]]) for (MBPoint *p in series) high=fmax(high,p.result.gb_per_second*1.12);
    double magnitude=pow(10,floor(log10(high/5))),step=ceil(high/5/magnitude)*magnitude; high=step*5;
    for (int j=0;j<=20;++j) {
        CGFloat y=NSMaxY(plot)-plot.size.height*j/20;
        NSBezierPath *line=[NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(plot.origin.x,y)]; [line lineToPoint:NSMakePoint(NSMaxX(plot),y)];
        [[grid colorWithAlphaComponent:j%4?0.4:0.9] setStroke]; line.lineWidth=0.6; [line stroke];
        if (j%4==0) [self text:[NSString stringWithFormat:@"%5.1f",j*step/4] at:NSMakePoint(5,y-7) color:muted size:10];
    }
    for (int j=0;j<=40;++j) {
        CGFloat x=plot.origin.x+plot.size.width*j/40;
        NSBezierPath *line=[NSBezierPath bezierPath]; [line moveToPoint:NSMakePoint(x,plot.origin.y)]; [line lineToPoint:NSMakePoint(x,NSMaxY(plot))];
        [[grid colorWithAlphaComponent:j%4?0.4:0.9] setStroke]; line.lineWidth=0.6; [line stroke];
        if (j%4==0) [self text:[NSString stringWithFormat:@"%dK",j/4-3] at:NSMakePoint(x-10,NSMaxY(plot)+9) color:muted size:10];
    }
    CGFloat zero=plot.origin.x+plot.size.width*0.3;
    NSBezierPath *axis=[NSBezierPath bezierPath]; CGFloat dash[]={3,4}; [axis setLineDash:dash count:2 phase:0];
    [axis moveToPoint:NSMakePoint(zero,plot.origin.y)]; [axis lineToPoint:NSMakePoint(zero,NSMaxY(plot))]; [[NSColor.whiteColor colorWithAlphaComponent:0.65] setStroke]; [axis stroke];
    [self text:self.mode==7?@"ЗАПИСЬ БЛОКА":@"ЧТЕНИЕ БЛОКА" at:NSMakePoint(20,16) color:muted size:11];
    for (unsigned block=32,i=0;block<=256;block*=2,++i)
        [self text:[NSString stringWithFormat:@"● %u байт",block] at:NSMakePoint(190+i*115,16) color:BlockColor(block) size:12];
    [self text:self.baseline.count?@"ПУНКТИР — ЭТАЛОН":@"МЕДИАНА ПОВТОРОВ" at:NSMakePoint(w-178,18) color:muted size:9];
    [self text:@"GB/s" at:NSMakePoint(12,57) color:muted size:10];
    [self text:@"ПРОПУСК · KiB (− НАЗАД, 0 ПОДРЯД)" at:NSMakePoint(w-280,h-17) color:muted size:9];
    for (unsigned block=32;block<=256;block*=2) {
        for (NSUInteger pass=0;pass<2;++pass) {
            NSArray *series=pass?self.points:self.baseline ?: @[];
            NSColor *color=BlockColor(block);
            CGFloat alpha=self.selectedBlock && self.selectedBlock!=block?0.25:pass?1:0.45;
            [[color colorWithAlphaComponent:alpha] setStroke];
            NSBezierPath *line=[NSBezierPath bezierPath]; line.lineWidth=pass?2.0:1.2;
            if (!pass) { CGFloat pattern[]={5,5}; [line setLineDash:pattern count:2 phase:0]; }
            BOOL first=YES;
            for (MBPoint *p in series) {
                mb_result r=p.result; if (r.block_bytes!=block) continue;
                NSPoint point=[self blockPosition:r value:r.gb_per_second plot:plot high:high];
                if (first) { [line moveToPoint:point]; first=NO; } else [line lineToPoint:point];
                if (pass && r.access_gap_bytes==self.selectedGap) {
                    [color setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(point.x-3,point.y-3,6,6)] fill];
                }
            }
            [line stroke];
        }
    }
    NSMutableArray *details=[NSMutableArray array];
    if (self.selectedGap!=NSIntegerMax) {
        [details addObject:[NSString stringWithFormat:@"Пропуск %ld B",(long)self.selectedGap]];
        for (MBPoint *p in self.points) if (p.result.access_gap_bytes==self.selectedGap)
            [details addObject:[NSString stringWithFormat:@"%u B: %.2f",p.result.block_bytes,p.result.gb_per_second]];
    }
    [self text:details.count?[details componentsJoinedByString:@"  /  "]:@"Наведи на график · выбери строку, чтобы выделить размер блока" at:NSMakePoint(20,40) color:muted size:10];
    if (!self.points.count) [self text:@"Начни тест: четыре блока, 47 вариантов доступа" at:NSMakePoint(MAX(70,(w-410)/2),h/2) color:muted size:13];
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    if (BlockMode(self.mode)) { [self drawBlockChart]; return; }
    [NSColor.blackColor setFill]; NSRectFill(self.bounds);
    CGFloat w=self.bounds.size.width, h=self.bounds.size.height;
    NSRect plot=NSMakeRect(64,76,MAX(1,w-88),MAX(1,h-120));
    double high=1;
    for (NSArray *series in @[self.points,self.baseline ?: @[]])
        for (MBPoint *p in series) { mb_result r=p.result; high=fmax(high,(series==self.points?mb_result_maximum(&r):(SummaryMode(self.mode)?mb_result_mean(&r):mb_result_value(&r)))*1.12); }
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
    NSString *legend=self.mode==5?@"● ЧТЕНИЕ · D-CACHE / RAM":@[@"● ЧТЕНИЕ · СРЕДНЕЕ",@"● ЧТЕНИЕ ПАМЯТИ",@"● ЗАПИСЬ ПАМЯТИ",@"● ЗАДЕРЖКА · МЕНЬШЕ ЛУЧШЕ"][self.mode];
    [self text:legend at:NSMakePoint(20,16) color:OperationColor(self.mode==2?MB_WRITE:self.mode==3?MB_LATENCY:MB_READ) size:12];
    if (SummaryMode(self.mode)) [self text:self.mode==5?@"● NOP-КОД · I-CACHE PROXY":@"● ЗАПИСЬ · СРЕДНЕЕ" at:NSMakePoint(310,16) color:OperationColor(self.mode==5?MB_EXECUTE:MB_WRITE) size:12];
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
                NSPoint point=[self position:r value:(SummaryMode(self.mode)?mb_result_mean(&r):mb_result_value(&r)) plot:plot high:high];
                if (first) { [path moveToPoint:point]; first=NO; } else [path lineToPoint:point];
                if (pass && (!SummaryMode(self.mode) || self.selectedBytes==r.bytes)) { [color setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(point.x-2,point.y-2,4,4)] fill]; }
            }
            [path stroke];
        }
    }
    if (self.selectedBytes) {
        NSMutableArray *details=[NSMutableArray arrayWithObject:SizeLabel(self.selectedBytes)];
        for (MBPoint *p in self.points) if (p.result.bytes==self.selectedBytes) {
            mb_result r=p.result;
            [details addObject:[NSString stringWithFormat:@"%s %.2f %s · CV %.1f%%",mb_operation_name(r.operation),(SummaryMode(self.mode)?mb_result_mean(&r):mb_result_value(&r)),mb_operation_unit(r.operation),r.cv_percent]];
            NSPoint point=[self position:r value:(SummaryMode(self.mode)?mb_result_mean(&r):mb_result_value(&r)) plot:plot high:high];
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
@property NSPopUpButton *maximumPopup, *profilePopup, *experimentPopup;
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
    self.experimentPopup.frame=NSMakeRect(gap,180,420,30);
    CGFloat chartHeight=h-564;
    self.chart.frame=NSMakeRect(gap,220,w-2*gap,chartHeight);
    CGFloat y=220+chartHeight+14;
    for (NSUInteger i=0;i<self.stats.count;++i) self.stats[i].frame=NSMakeRect(gap+i*(w-2*gap)/3,y,(w-2*gap)/3-10,42);
    self.tableScroll.frame=NSMakeRect(gap,y+52,w-2*gap,160);
    self.noteLabel.frame=NSMakeRect(gap,h-110,w-2*gap,32);
    self.startButton.frame=NSMakeRect(w-178,h-47,154,30);
    self.baselineButton.frame=NSMakeRect(gap,h-47,192,30);
    self.exportButton.frame=NSMakeRect(gap+204,h-47,120,30);
    self.jsonButton.frame=NSMakeRect(gap+336,h-47,120,30);
    self.progress.frame=NSMakeRect(gap,h-12,w-2*gap,4);
    self.statusLabel.frame=NSMakeRect(gap,h-72,w-2*gap,20);
    self.aboutScroll.frame=NSMakeRect(gap,220,w-2*gap,h-326);
    self.chart.hidden=self.showingAbout; self.tableScroll.hidden=self.showingAbout;
    self.noteLabel.hidden=self.showingAbout; self.aboutScroll.hidden=!self.showingAbout;
    for (NSTextField *label in self.stats) label.hidden=self.showingAbout;
    self.experimentPopup.hidden=self.showingAbout;
}
@end

@interface MBApp : NSObject <NSApplicationDelegate,NSTableViewDataSource,NSTableViewDelegate>
@property NSWindow *window;
@property MBContent *content;
@property NSTableView *table;
@property NSArray<NSDictionary *> *rangeRows, *blockRows;
@property NSMutableArray<MBPoint *> *points;
@property NSMutableDictionary<NSNumber *,NSArray<MBPoint *> *> *resultsByMode;
@property NSMutableDictionary<NSNumber *,NSDictionary *> *metadataByMode;
@property mb_context *context;
@property BOOL running, smokeTest;
@property NSUInteger smokePass;
@property NSInteger selectedMode, activeMode;
@property NSMutableDictionary<NSNumber *,NSNumber *> *experiments;
@property NSMutableDictionary<NSNumber *,NSArray<NSNumber *> *> *settingsByMode;
@property double activeProgress;
@property BOOL stopping, navigationTest;
@property id activity;
@property NSMutableDictionary<NSNumber *, NSDictionary *> *baselines;
@property NSTimer *conditionTimer;
@end

@implementation MBApp
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    self.smokeTest=[NSProcessInfo.processInfo.arguments containsObject:@"--smoke-test"];
    self.selectedMode=5; self.activeMode=-1; self.experiments=[@{@0:@5,@1:@6,@2:@7} mutableCopy]; self.settingsByMode=[NSMutableDictionary dictionary];
    self.points=[NSMutableArray array]; self.resultsByMode=[NSMutableDictionary dictionary]; self.metadataByMode=[NSMutableDictionary dictionary];
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1080,880) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"Memory Benchmark — Mac";
    self.window.minSize=NSMakeSize(1000,800); self.window.releasedWhenClosed=NO;
    self.window.backgroundColor=NSColor.windowBackgroundColor;
    self.content=[[MBContent alloc] initWithFrame:self.window.contentView.bounds];
    self.content.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    self.window.contentView=self.content; MBContent *v=self.content;
    NSColor *dark=NSColor.labelColor, *muted=[NSColor secondaryLabelColor];
    v.titleLabel=Label(@"Memory Lab  /  2.3",27,NSFontWeightSemibold,dark);
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
    v.experimentPopup=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    v.experimentPopup.target=self; v.experimentPopup.action=@selector(changeExperiment:);
    v.experimentPopup.toolTip=@"Выбор измерения внутри вкладки. Результаты каждого режима сохраняются до закрытия приложения.";
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
    v.baselineButton.toolTip=@"Сохранить завершённый прогон этой вкладки для сравнения. Эталон остаётся после перезапуска приложения.";
    v.conditionLabel=Label(@"",11,NSFontWeightMedium,muted);
    v.aboutScroll=[[NSScrollView alloc] initWithFrame:NSZeroRect]; v.aboutScroll.hasVerticalScroller=YES;
    NSTextView *about=[[NSTextView alloc] initWithFrame:NSMakeRect(0,0,960,650)]; about.editable=NO; about.selectable=YES;
    about.font=[NSFont systemFontOfSize:14]; about.backgroundColor=self.window.backgroundColor;
    about.textContainerInset=NSMakeSize(12,12); about.autoresizingMask=NSViewWidthSizable; about.textContainer.widthTracksTextView=YES;
    about.string=@"Memory Lab · 2.3\n\nCache Speed\nДве серии: чтение данных и последовательное выполнение NOP-кода. Шкала рабочего набора логарифмическая; 16 интервалов на удвоение. NOP-код — косвенный тест фронтенда процессора, не физическая пропускная способность I-cache; GB/s означает объём кода в секунду. Код ограничен 64 MiB. В меню под вкладками сохранён прежний режим чтения и записи с пятью строками сводки. Размеры в сводке — опорные буферы, не обнаруженные уровни кэша. Сведения о кэшах из macOS показаны над вкладками.\n\nRead RAM / Write RAM\nРежим «Блоки»: четыре серии по 32, 64, 128 и 256 байт. Ось X — знаковый пропуск между соседними блоками: шаг равен размеру блока плюс модуль пропуска. Отрицательные значения обходят тот же набор адресов в обратном порядке; ноль означает последовательный доступ. Буфер фиксирован выбранным максимумом. На каждой точке — медиана повторов, без сглаживания. Скорость считает только явно прочитанные или записанные байты, а не весь буфер и не физический трафик DRAM. Мин./макс./среднее в таблице рассчитаны по медианам всех 47 условий; «подряд» — точка ноль, процент — среднее / подряд × 100. Процент может превышать 100 и не означает эффективность железа. Алгоритм адаптирован для Mac; совпадение методики или чисел с программой преподавателя не предполагается. Классический профиль по размеру буфера сохранён вторым пунктом меню.\n\nLatency и качество\nЗависимые случайные чтения, узел через 128 байт: ns/load, меньше лучше. Не чистая задержка DRAM. Быстрый: 15 мс × 3; баланс: 35 мс × 5; точный: 60 мс × 9. Буфер прогревается; macOS выбирает ядро. CV > 5% — повод повторить измерение без фоновой нагрузки. Лимит — 1 GiB и ⅛ RAM.\n\nВкладки и результаты\nВо время теста можно открывать любую вкладку и «О программе». Одновременно работает только один тест; кнопка остановки управляет им из любой вкладки. Каждый режим сохраняет свои результаты и настройки до закрытия приложения. CSV/JSON можно экспортировать и во время теста как незавершённый снимок. Эталоном становится только полный прогон; он сохраняется между запусками. Пунктир сравнивает совместимые настройки, включая метод обхода.\n\nЭто не тест исправности памяти, GPU или многопоточного максимума. Данные остаются на устройстве. Подробности — README.md и VALIDATION.md.";
    v.aboutScroll.documentView=about;
    for (NSView *view in @[v.titleLabel,v.machineLabel,v.cacheLabel,v.tabs,v.rangeLabel,v.maximumPopup,v.profileLabel,v.profilePopup,v.chart,v.tableScroll,v.noteLabel,v.statusLabel,v.progress,v.startButton,v.exportButton,v.jsonButton,v.baselineButton,v.conditionLabel,v.aboutScroll,v.experimentPopup]) [v addSubview:view];
    self.baselines=[NSMutableDictionary dictionary]; [self loadBaselines];
    self.conditionTimer=[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(updateConditions:) userInfo:nil repeats:YES];
    [self updateConditions:nil]; [self changeTab:nil];
    [self createMenu]; [v setNeedsLayout:YES]; [self.window center]; [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    if (self.smokeTest) {
        NSString *mode=NSProcessInfo.processInfo.environment[@"MB_SMOKE_MODE"];
        self.navigationTest=[mode isEqual:@"navigation"];
        NSInteger selected=[mode isEqual:@"ranges"]?0:[mode isEqual:@"cache"]?5:[mode isEqual:@"blocks-read"]?6:([mode isEqual:@"blocks-write"] || self.navigationTest)?7:3;
        NSInteger tab=selected==5?0:selected==6?1:selected==7?2:selected;
        if (tab<3) self.experiments[@(tab)]=@(selected);
        self.content.tabs.selectedSegment=tab; [self changeTab:nil];
        [self.content.maximumPopup selectItemAtIndex:0]; [self.content.profilePopup selectItemAtIndex:0];
        [self startOrStop:nil];
    }
}
- (void)configureTable {
    NSArray *titles=BlockMode(self.selectedMode)?@[@"Блок",@"Мин. GB/s",@"Макс. GB/s",@"Сред. GB/s",@"Подряд GB/s",@"Сред. / подряд"]:
        SummaryMode(self.selectedMode)?@[@"Буфер",@"Чт. мин",@"Чт. сред.",@"Чт. макс.",@"Чт. %",self.selectedMode==5?@"Код мин":@"Зап. мин",self.selectedMode==5?@"Код сред.":@"Зап. сред.",self.selectedMode==5?@"Код макс.":@"Зап. макс.",self.selectedMode==5?@"Код %":@"Зап. %"]:
        @[@"Буфер",@"Операция",@"Медиана",@"Мин. — макс.",@"CV, %",@"К эталону"];
    [self.table deselectAll:nil];
    for (NSTableColumn *column in self.table.tableColumns.copy) [self.table removeTableColumn:column];
    for (NSUInteger i=0;i<titles.count;++i) {
        NSTableColumn *column=[[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%lu",(unsigned long)i]];
        column.headerCell=[[MBHeaderCell alloc] initTextCell:titles[i]]; column.title=titles[i];
        column.width=SummaryMode(self.selectedMode)?108:154; column.minWidth=70;
        column.headerToolTip=BlockMode(self.selectedMode)?@"Минимум, максимум и среднее медиан по всем пропускам. Подряд = пропуск 0. Процент = среднее / подряд × 100, только полный тест.":@"GB/s. Для NOP-кода — объём инструкций в секунду, не физическая скорость I-cache. % — среднее / лучшее среднее среди пяти строк.";
        [self.table addTableColumn:column];
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
- (void)showAbout:(id)sender { (void)sender; self.content.tabs.selectedSegment=4; [self changeTab:nil]; }
- (void)rememberSettings {
    if (self.selectedMode!=4) self.settingsByMode[@(self.selectedMode)]=@[@(self.content.maximumPopup.indexOfSelectedItem),@(self.content.profilePopup.indexOfSelectedItem)];
}
- (void)changeExperiment:(id)sender {
    (void)sender; NSInteger tab=self.content.tabs.selectedSegment;
    if (tab<3) self.experiments[@(tab)]=@(self.content.experimentPopup.indexOfSelectedItem==0?(tab==0?5:tab+5):tab);
    [self changeTab:nil];
}
- (void)changeTab:(id)sender {
    (void)sender; [self rememberSettings];
    NSInteger tab=self.content.tabs.selectedSegment;
    if (tab<0 || tab>4) return;
    self.selectedMode=tab<3?[self.experiments[@(tab)] integerValue]:tab;
    NSInteger mode=self.selectedMode;
    [self.content.experimentPopup removeAllItems];
    [self.content.experimentPopup addItemsWithTitles:tab==0?@[@"D-cache + I-cache · чтение и NOP-код",@"5 диапазонов · чтение и запись"]:
        tab==1 || tab==2?@[@"Блоки 32 / 64 / 128 / 256 байт · шаг доступа",@"Классический профиль · размер буфера"]:@[@"Задержка · зависимые случайные чтения"]];
    [self.content.experimentPopup selectItemAtIndex:mode<3?1:0];
    self.content.experimentPopup.enabled=tab<3;
    self.content.showingAbout=tab==4;
    NSArray *settings=self.settingsByMode[@(mode)];
    if (settings) { [self.content.maximumPopup selectItemAtIndex:[settings[0] integerValue]]; [self.content.profilePopup selectItemAtIndex:[settings[1] integerValue]]; }
    self.points=[self.resultsByMode[@(mode)] mutableCopy] ?: [NSMutableArray array];
    self.content.chart.points=self.points; self.content.chart.mode=mode==4?3:mode;
    self.content.chart.selectedBytes=0; self.content.chart.selectedGap=NSIntegerMax; self.content.chart.selectedBlock=0;
    NSDictionary *meta=self.metadataByMode[@(mode)];
    const size_t maxima[]={64UL*1024*1024,256UL*1024*1024,512UL*1024*1024,1024UL*1024*1024};
    self.content.chart.maximum=meta?[meta[@"maximum_bytes"] unsignedLongLongValue]:maxima[self.content.maximumPopup.indexOfSelectedItem];
    [self configureTable]; [self refreshResults]; [self updateControls];
    [self.content setNeedsLayout:YES];
}
- (void)updateControls {
    BOOL about=self.selectedMode==4, active=self.running && self.activeMode==self.selectedMode;
    self.content.tabs.enabled=YES;
    self.content.maximumPopup.enabled=!active && !about; self.content.profilePopup.enabled=!active && !about;
    self.content.startButton.enabled=!self.stopping && (self.running || !about);
    self.content.startButton.title=self.running?(self.stopping?@"Останавливаю…":@"Остановить тест"):@"Начать тест";
    self.content.startButton.toolTip=self.running?[NSString stringWithFormat:@"Остановить активный %@. Одновременно выполняется одно измерение.",ModeName(self.activeMode)]:@"Запустить выбранное измерение";
    self.content.exportButton.enabled=!about && self.points.count>0;
    self.content.jsonButton.enabled=self.content.exportButton.enabled;
    self.content.baselineButton.enabled=!about && !active && [self.metadataByMode[@(self.selectedMode)][@"complete"] boolValue];
    self.content.progress.doubleValue=self.running?self.activeProgress:([self.metadataByMode[@(self.selectedMode)][@"complete"] boolValue]?1:0);
    self.content.statusLabel.stringValue=self.running?[NSString stringWithFormat:@"%@%@ · %.0f%% · вкладки доступны",self.stopping?@"Останавливаю ":@"Идёт ",ModeName(self.activeMode),100*self.activeProgress]:self.metadataByMode[@(self.selectedMode)][@"state"] ?: @"Готов к тесту · закрой тяжёлые приложения";
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
    for (NSInteger mode=0;mode<8;++mode) {
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
    if (SummaryMode(self.selectedMode)) report[@"range_summary"]=MBRangeSummary(report);
    if (BlockMode(self.selectedMode)) report[@"block_summary"]=MBBlockSummary(report);
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
        if (b.bytes==r.bytes && b.operation==r.operation && b.block_bytes==r.block_bytes && b.access_gap_bytes==r.access_gap_bytes) {
            double value=SummaryMode(self.selectedMode)?mb_result_mean(&r):mb_result_value(&r), baseline=SummaryMode(self.selectedMode)?mb_result_mean(&b):mb_result_value(&b);
            return @((r.operation==MB_LATENCY?(baseline-value)/baseline:value/baseline-1)*100);
        }
    }
    return nil;
}
- (void)saveBaseline:(id)sender {
    (void)sender; if (self.running && self.activeMode==self.selectedMode) return;
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
        NSMutableDictionary *meta=(NSMutableDictionary *)self.metadataByMode[@(self.activeMode)];
        meta[@"thermal_peak"]=@(MAX([meta[@"thermal_peak"] integerValue],info.thermalState));
        if ([meta[@"low_power"] boolValue]!=info.lowPowerModeEnabled) meta[@"power_changed"]=@YES;
    }
}
- (void)refreshResults {
    if (SummaryMode(self.selectedMode)) {
        NSDictionary *report=[self currentReport];
        if (![report[@"metadata"] count]) report=@{@"metadata":@{@"mode":ModeName(self.selectedMode),@"maximum_bytes":@(self.content.chart.maximum)},@"points":@[]};
        self.rangeRows=MBRangeSummary(report);
    }
    if (BlockMode(self.selectedMode)) self.blockRows=MBBlockSummary([self currentReport]);
    self.content.chart.baseline=[self comparableBaseline];
    [self.content.chart setNeedsDisplay:YES]; [self.table reloadData];
    MBPoint *primary=nil;
    mb_operation operation=(self.selectedMode==2 || self.selectedMode==7)?MB_WRITE:self.selectedMode==3?MB_LATENCY:MB_READ;
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
    if (SummaryMode(self.selectedMode)) {
        for (NSUInteger op=0;op<2;++op) {
            double best=0;
            for (NSDictionary *row in self.rangeRows) best=fmax(best,[row[op==0?@"read":self.selectedMode==5?@"execute_proxy":@"write"][@"mean"] doubleValue]);
            self.content.stats[op].stringValue=best>0?[NSString stringWithFormat:@"%@: %.2f GB/s\nЛучшее среднее из 5 строк",op==0?@"Чтение":self.selectedMode==5?@"NOP-код":@"Запись",best]:[NSString stringWithFormat:@"%@: —",op==0?@"Чтение":self.selectedMode==5?@"NOP-код":@"Запись"];
        }
        size_t chartSizes[MB_PROFILE_CAPACITY];
        size_t count=mb_profile_sizes(self.content.chart.maximum,chartSizes,MB_PROFILE_CAPACITY), expected=count;
        for (size_t i=0;i<count;++i) if (self.selectedMode==0 || chartSizes[i]<=64UL*1024*1024) ++expected;
        self.content.stats[2].stringValue=MBValidReport([self currentReport])?[NSString stringWithFormat:@"%lu размеров · 5 строк\n100%% = лучшее среднее из 5 строк",(unsigned long)count]:[NSString stringWithFormat:@"%lu / %zu измерений\nПроценты — после полного теста",(unsigned long)self.points.count,expected];
    }
    if (BlockMode(self.selectedMode)) {
        self.content.stats[0].stringValue=[NSString stringWithFormat:@"4 размера блока · %@ буфер",SizeLabel(self.content.chart.maximum)];
        self.content.stats[1].stringValue=[NSString stringWithFormat:@"%lu / %d точек · GB/s",(unsigned long)self.points.count,4*MB_GAP_CAPACITY];
        self.content.stats[2].stringValue=@"0 = подряд · минус = назад\nПунктир — сохранённый эталон";
    }
    for (NSTextField *label in self.content.stats) label.font=[NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    NSMutableArray *notes=[NSMutableArray array];
    if (noisy) [notes addObject:[NSString stringWithFormat:@"%lu точек с CV > 5%%: попробуй точный режим и закрой фоновые задачи.",(unsigned long)noisy]];
    NSDictionary *meta=self.metadataByMode[@(self.selectedMode)];
    if ([meta[@"thermal_peak"] integerValue]>=NSProcessInfoThermalStateSerious) [notes addObject:@"Во время прогона macOS сообщала о сильном нагреве."];
    if ([meta[@"power_changed"] boolValue]) [notes addObject:@"Режим питания менялся во время теста."];
    [notes addObject:BlockMode(self.selectedMode)?@"Пропуск между блоками; шаг = блок + |пропуск|. Скорость по прочитанным/записанным байтам. Среднее / подряд — не КПД DRAM.":self.selectedMode==5?@"Чтение и NOP-код: влияние рабочего набора. NOP GB/s — объём кода/с, не пропускная способность I-cache. Таблица — 5 опорных размеров.":self.selectedMode==3?@"Зависимые случайные чтения · 128 байт между узлами · ns/load: меньше лучше.":SummaryMode(self.selectedMode)?@"Подробный график; таблица — 5 размеров, не уровни кэша. GB/s; % — относительно лучшей из 5 строк той же операции.":@"Один поток · GB/s = 10⁹ байт/с · график показывает медиану и min–max."];
    self.content.noteLabel.stringValue=[notes componentsJoinedByString:@" "];
    self.content.noteLabel.toolTip=self.content.noteLabel.stringValue;
    [self updateControls];
}
- (void)startOrStop:(id)sender {
    (void)sender;
    if (self.running) { mb_cancel(self.context); self.stopping=YES; [self updateControls]; return; }
    if (self.selectedMode==4) return;
    [self rememberSettings];
    const size_t maxima[]={64UL*1024*1024,256UL*1024*1024,512UL*1024*1024,1024UL*1024*1024};
    size_t maximum=maxima[self.content.maximumPopup.indexOfSelectedItem];
    if (maximum>NSProcessInfo.processInfo.physicalMemory/8) { [self showError:@"Выбери меньший буфер: лимит — ⅛ установленной памяти."]; return; }
    mb_context *ctx=mb_create(); if (!ctx) { [self showError:@"Не удалось создать измерительный контекст."]; return; }
    NSInteger mode=self.selectedMode, profile=self.content.profilePopup.indexOfSelectedItem;
    self.context=ctx; self.running=YES; self.stopping=NO; self.activeMode=mode; self.activeProgress=0;
    NSMutableArray<MBPoint *> *runPoints=[NSMutableArray array];
    self.resultsByMode[@(mode)]=runPoints; self.points=runPoints;
    self.content.chart.points=runPoints; self.content.chart.maximum=maximum;
    const double durations[]={0.015,0.035,0.060}; const unsigned sampleCounts[]={3,5,9};
    double seconds=durations[profile]; unsigned samples=sampleCounts[profile];
    NSString *started=[NSISO8601DateFormatter.new stringFromDate:NSDate.date];
    NSMutableDictionary *metadata=[@{@"method":@(mb_method_version()),@"machine":self.content.machineLabel.stringValue,@"caches":self.content.cacheLabel.stringValue,@"started":started,@"mode":ModeName(mode),@"maximum_bytes":@(maximum),@"seconds_per_sample":@(seconds),@"samples":@(samples),@"threads":@1,@"state":@"Выполняется",@"low_power":@(NSProcessInfo.processInfo.lowPowerModeEnabled),@"thermal_start":@(NSProcessInfo.processInfo.thermalState),@"thermal_peak":@(NSProcessInfo.processInfo.thermalState),@"complete":@NO,@"profile":@[@"quick",@"standard",@"precise"][profile],@"latency_stride_bytes":@(MB_LATENCY_STRIDE),@"order":@"ascending"} mutableCopy];
    if (mode==0) metadata[@"sweep"]=@"dense-16-v1";
    if (mode==5) metadata[@"sweep"]=@"cache-dense-v1";
    if (BlockMode(mode)) {
        metadata[@"sweep"]=@"block-gap-v1";
        metadata[@"address_step"]=@"block_bytes + abs(access_gap_bytes); negative gap reverses traversal; zero is contiguous";
        metadata[@"traffic"]=@"explicit bytes accessed, excluding gaps; not physical DRAM traffic";
    }
    self.metadataByMode[@(mode)]=metadata;
    self.activity=[NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated reason:@"Memory benchmark"];
    [self refreshResults];
    if (self.smokeTest) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,150*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{ [self testNavigationDuringRun]; });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        @autoreleasepool {
            size_t sizes[MB_PROFILE_CAPACITY],completed=0,total=0,count=0;
            int gaps[MB_GAP_CAPACITY];
            if (BlockMode(mode)) { count=mb_access_gaps(gaps,MB_GAP_CAPACITY); total=count*4; }
            else {
                count=SummaryMode(mode)?mb_profile_sizes(maximum,sizes,MB_PROFILE_CAPACITY):mb_sizes(maximum,sizes,MB_PROFILE_CAPACITY);
                total=count;
                for (size_t i=0;i<count;++i) if (mode==0 || (mode==5 && sizes[i]<=64UL*1024*1024)) ++total;
            }
            NSString *failure=count?nil:@"Не удалось построить план теста.";
            for (size_t i=0;i<count && !mb_is_cancelled(ctx) && !failure;++i) {
                unsigned operations=BlockMode(mode)?4:mode==0 || (mode==5 && sizes[i]<=64UL*1024*1024)?2:1;
                for (unsigned j=0;j<operations;++j) {
                    mb_operation op=(mode==2 || mode==7)?MB_WRITE:mode==3?MB_LATENCY:j==1 && !BlockMode(mode)?(mode==5?MB_EXECUTE:MB_WRITE):MB_READ;
                    mb_result result;
                    mb_status status=BlockMode(mode)?mb_measure_blocks(ctx,op,maximum,32U<<j,gaps[i],seconds,samples,&result):mb_measure(ctx,op,sizes[i],seconds,samples,&result);
                    if (status==MB_CANCELLED) break;
                    if (status!=MB_OK) { failure=[NSString stringWithUTF8String:mb_error(ctx)]; break; }
                    MBPoint *point=[MBPoint new]; point.result=result; ++completed;
                    double progress=(double)completed/total;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [runPoints addObject:point]; self.activeProgress=progress;
                        if (self.selectedMode==mode) { self.points=runPoints; self.content.chart.points=runPoints; [self refreshResults]; }
                        else [self updateControls];
                    });
                }
            }
            BOOL cancelled=mb_is_cancelled(ctx);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.running=NO; self.context=NULL; self.stopping=NO; self.activeMode=-1; mb_destroy(ctx);
                [NSProcessInfo.processInfo endActivity:self.activity]; self.activity=nil;
                NSString *state=failure?@"Ошибка · частичные результаты":cancelled?@"Остановлен · частичные результаты":@"Готово";
                metadata[@"state"]=state; metadata[@"complete"]=@(!cancelled && !failure && completed==total);
                metadata[@"thermal_peak"]=@(MAX([metadata[@"thermal_peak"] integerValue],NSProcessInfo.processInfo.thermalState));
                if ([metadata[@"low_power"] boolValue]!=NSProcessInfo.processInfo.lowPowerModeEnabled) metadata[@"power_changed"]=@YES;
                metadata[@"thermal_end"]=@(NSProcessInfo.processInfo.thermalState);
                metadata[@"finished"]=[NSISO8601DateFormatter.new stringFromDate:NSDate.date];
                if (failure) metadata[@"error"]=failure;
                self.resultsByMode[@(mode)]=[runPoints copy];
                if (self.selectedMode==mode) { self.points=[runPoints mutableCopy]; self.content.chart.points=self.points; }
                [self refreshResults];
                if (self.smokeTest) {
                    if (self.navigationTest && self.smokePass==0) {
                        if (!cancelled || [metadata[@"complete"] boolValue] || self.content.baselineButton.enabled) exit(1);
                        self.smokePass=2; self.experiments[@2]=@7; self.content.tabs.selectedSegment=2; [self changeTab:nil];
                        [self startOrStop:nil]; return;
                    }
                    if (failure || cancelled || !runPoints.count) { fprintf(stderr,"Smoke failure: %s\n",failure.UTF8String ?: "cancelled/empty"); exit(1); }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{ [self finishSmokeTest]; });
                } else if (failure) [self showError:failure];
            });
        }
    });
}
- (void)testNavigationDuringRun {
    if (!self.running) { fprintf(stderr,"Navigation test missed running state\n"); exit(1); }
    fprintf(stderr,"SMOKE navigation start\n");
    NSInteger mode=self.activeMode;
    NSArray *original=[self.resultsByMode[@(mode)] copy];
    mb_context *context=self.context;
    for (NSInteger tab=0;tab<5;++tab) {
        fprintf(stderr,"SMOKE tab %ld\n",(long)tab);
        self.content.tabs.selectedSegment=tab;
        [NSApp sendAction:self.content.tabs.action to:self.content.tabs.target from:self.content.tabs];
        [self.content layoutSubtreeIfNeeded];
        NSView *hit=[self.content hitTest:[self.content convertPoint:NSMakePoint(NSMidX(self.content.tabs.frame),NSMidY(self.content.tabs.frame)) toView:self.content.superview]];
        if (hit!=self.content.tabs && ![hit isDescendantOf:self.content.tabs]) { fprintf(stderr,"Tabs intercepted by another view\n"); exit(1); }
        if (!self.content.tabs.enabled || self.content.showingAbout!=(tab==4) || self.activeMode!=mode || self.context!=context) exit(1);
        if (tab<3) {
            [self.content.experimentPopup selectItemAtIndex:1]; [self changeExperiment:nil];
            if (self.selectedMode!=tab || self.context!=context) exit(1);
            [self.content.experimentPopup selectItemAtIndex:0]; [self changeExperiment:nil];
        }
    }
    // All navigation was synchronous on the main queue: no result may move to another mode.
    if (![self.resultsByMode[@(mode)] isEqual:original]) exit(1);
    NSInteger tab=mode==5?0:mode==6?1:mode==7?2:mode;
    if (tab<3) self.experiments[@(tab)]=@(mode);
    self.content.tabs.selectedSegment=tab; [self changeTab:nil];
    if (self.selectedMode!=mode || self.content.chart.points.count!=original.count) exit(1);
    fprintf(stderr,"SMOKE navigation complete\n");
    if (self.navigationTest && self.smokePass==0) {
        self.content.tabs.selectedSegment=4; [self changeTab:nil];
        [self startOrStop:nil];
        if (!self.stopping || self.content.startButton.enabled) exit(1);
    }
}
- (void)writeSmokeScreenshot:(NSString *)path {
    [self.content layoutSubtreeIfNeeded]; [self.content display];
    NSBitmapImageRep *bitmap=[self.content bitmapImageRepForCachingDisplayInRect:self.content.bounds];
    [self.content cacheDisplayInRect:self.content.bounds toBitmapImageRep:bitmap];
    NSData *png=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (![png writeToFile:path atomically:YES]) exit(1);
}
- (void)finishSmokeTest {
    if (SummaryMode(self.selectedMode)) {
        size_t sizes[MB_PROFILE_CAPACITY];
        size_t expected=2*mb_profile_sizes(self.content.chart.maximum,sizes,MB_PROFILE_CAPACITY);
        if (self.table.numberOfRows!=5 || self.table.tableColumns.count!=9 || self.points.count!=expected || expected<=10 || !MBValidReport([self currentReport])) exit(1);
        for (NSString *op in @[@"read",self.selectedMode==5?@"execute_proxy":@"write"]) {
            double best=0;
            for (NSDictionary *row in self.rangeRows) {
                NSNumber *percent=row[op][@"relative_speed_percent"];
                if (!percent || percent.doubleValue<=0 || percent.doubleValue>100) exit(1);
                best=fmax(best,percent.doubleValue);
            }
            if (fabs(best-100)>1e-9) exit(1);
        }
    }
    if (BlockMode(self.selectedMode)) {
        if (self.table.numberOfRows!=4 || self.points.count!=4*MB_GAP_CAPACITY || !MBValidReport([self currentReport])) exit(1);
        for (NSDictionary *row in self.blockRows) if ([row[@"conditions"] unsignedIntegerValue]!=MB_GAP_CAPACITY || !row[@"relative_speed_percent"]) exit(1);
    }
    if (self.smokePass!=1) {
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
- (NSInteger)numberOfRowsInTableView:(NSTableView *)view { (void)view; return BlockMode(self.selectedMode)?self.blockRows.count:SummaryMode(self.selectedMode)?self.rangeRows.count:self.points.count; }
- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)table;
    if (BlockMode(self.selectedMode)) {
        NSDictionary *value=self.blockRows[row]; NSInteger col=column.identifier.integerValue;
        NSNumber *n=col?value[@[@"minimum",@"maximum",@"mean",@"linear",@"relative_speed_percent"][col-1]]:value[@"block_bytes"];
        NSString *text=!n?@"—":col==0?[NSString stringWithFormat:@"%u байт",n.unsignedIntValue]:[NSString stringWithFormat:col==5?@"%.1f%%":@"%.3f",n.doubleValue];
        NSTextField *label=Label(text,11,NSFontWeightRegular,NSColor.labelColor);
        label.font=[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]; return label;
    }
    if (SummaryMode(self.selectedMode)) {
        NSDictionary *range=self.rangeRows[row]; NSInteger col=column.identifier.integerValue;
        NSString *text=SizeLabel([range[@"buffer_bytes"] unsignedLongLongValue]);
        if (col>0) {
            NSDictionary *value=range[col<5?@"read":self.selectedMode==5?@"execute_proxy":@"write"];
            NSString *key=@[@"minimum",@"mean",@"maximum",@"relative_speed_percent"][(col-1)%4];
            NSNumber *number=value[key];
            text=number?[NSString stringWithFormat:(col==4 || col==8)?@"%.1f%%":@"%.3f",number.doubleValue]:@"—";
        }
        NSTextField *label=Label(text,11,NSFontWeightRegular,NSColor.labelColor);
        label.font=[NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular]; return label;
    }
    mb_result r=self.points[row].result; NSString *text=@"";
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
    if (BlockMode(self.selectedMode)) { self.content.chart.selectedBlock=(row>=0 && row<4)?32U<<(unsigned)row:0; [self.content.chart setNeedsDisplay:YES]; return; }
    self.content.chart.selectedBytes=SummaryMode(self.selectedMode)?
        ((row>=0 && row<(NSInteger)self.rangeRows.count)?[self.rangeRows[row][@"buffer_bytes"] unsignedLongLongValue]:0):
        ((row>=0 && row<(NSInteger)self.points.count)?self.points[row].result.bytes:0);
    [self.content.chart setNeedsDisplay:YES];
}
- (void)exportCSV:(id)sender { (void)sender; [self exportReportJSON:NO]; }
- (void)exportJSON:(id)sender { (void)sender; [self exportReportJSON:YES]; }
- (void)exportReportJSON:(BOOL)json {
    if (self.selectedMode==4 || !self.points.count) return;
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

static void SmokeSignal(int number) {
    void *stack[80]; int count=backtrace(stack,80); backtrace_symbols_fd(stack,count,STDERR_FILENO); _Exit(128+number);
}
int main(int argc,const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        if ([NSProcessInfo.processInfo.arguments containsObject:@"--smoke-test"]) { signal(SIGSEGV,SmokeSignal); signal(SIGABRT,SmokeSignal); }
        NSApplication *app=NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        __attribute__((objc_precise_lifetime)) MBApp *delegate=[MBApp new]; app.delegate=delegate;
        [app run];
    }
    return 0;
}



