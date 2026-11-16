#import "report.h"
#include <math.h>
#include <string.h>

NSDictionary *MBPointRecord(mb_result r) {
    NSMutableArray *samples=[NSMutableArray array];
    for (unsigned i=0;i<r.samples;++i) [samples addObject:@(r.sample_values[i])];
    return @{@"operation":@(r.operation),@"operation_name":@(mb_operation_name(r.operation)),
        @"buffer_bytes":@(r.bytes),@"unit":@(mb_operation_unit(r.operation)),
        @"median":@(mb_result_value(&r)),@"minimum":@(mb_result_minimum(&r)),
        @"maximum":@(mb_result_maximum(&r)),@"cv_percent":@(r.cv_percent),
        @"total_sample_seconds":@(r.seconds),@"iterations":@(r.passes),@"samples":@(r.samples),@"sample_values":samples};
}
static BOOL Number(id n) { return [n isKindOfClass:NSNumber.class] && isfinite([n doubleValue]); }
BOOL MBDecodePoint(id d, mb_result *out) {
    if (!out || ![d isKindOfClass:NSDictionary.class]) return NO;
    memset(out,0,sizeof(*out));
    for (NSString *key in @[@"operation",@"buffer_bytes",@"median",@"minimum",@"maximum",@"cv_percent",@"total_sample_seconds",@"iterations",@"samples"])
        if (!Number(d[key])) return NO;
    NSInteger op=[d[@"operation"] integerValue];
    double bytes=[d[@"buffer_bytes"] doubleValue], count=[d[@"samples"] doubleValue];
    if (op<MB_READ || op>MB_LATENCY || [d[@"operation"] doubleValue]!=op ||
        bytes<4096 || bytes>1024.*1024*1024 || fmod(bytes,256)!=0 ||
        (op==MB_EXECUTE && bytes>64.*1024*1024) || count<1 || count>MB_MAX_SAMPLES || floor(count)!=count ||
        [d[@"total_sample_seconds"] doubleValue]<=0 || [d[@"iterations"] doubleValue]<count) return NO;
    if (![d[@"unit"] isEqual:@(mb_operation_unit((mb_operation)op))]) return NO;
    id samples=d[@"sample_values"];
    if (![samples isKindOfClass:NSArray.class] || [samples count]!=(NSUInteger)count) return NO;
    for (unsigned i=0;i<(unsigned)count;++i) {
        if (!Number(samples[i])) return NO;
        out->sample_values[i]=[samples[i] doubleValue];
    }
    mb_statistics stats;
    if (!mb_summarize(out->sample_values,(unsigned)count,&stats)) return NO;
    /* Recompute statistics rather than trust persisted summaries. */
    out->bytes=(size_t)bytes; out->operation=(mb_operation)op; out->samples=(unsigned)count;
    out->seconds=[d[@"total_sample_seconds"] doubleValue]; out->passes=[d[@"iterations"] unsignedLongLongValue];
    out->cv_percent=stats.cv_percent;
    if (op==MB_LATENCY) {
        out->nanoseconds_per_load=stats.median;
        out->minimum_nanoseconds_per_load=stats.minimum; out->maximum_nanoseconds_per_load=stats.maximum;
    } else {
        out->gb_per_second=stats.median; out->minimum_gb_per_second=stats.minimum; out->maximum_gb_per_second=stats.maximum;
    }
    return YES;
}
BOOL MBComparable(NSDictionary *a, NSDictionary *b) {
    if (![a isKindOfClass:NSDictionary.class] || ![b isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in @[@"method",@"machine",@"mode",@"maximum_bytes",@"seconds_per_sample",@"samples",@"threads",@"low_power"])
        if (!a[key] || ![a[key] isEqual:b[key]]) return NO;
    return [b[@"complete"] isEqual:@YES] && ![a[@"power_changed"] boolValue] && ![b[@"power_changed"] boolValue];
}
BOOL MBValidReport(id report) {
    if (![report isKindOfClass:NSDictionary.class] || ![report[@"schema_version"] isEqual:@2] ||
        ![report[@"metadata"] isKindOfClass:NSDictionary.class] ||
        ![report[@"points"] isKindOfClass:NSArray.class]) return NO;
    NSDictionary *meta=report[@"metadata"]; NSArray *points=report[@"points"];
    if (![meta[@"method"] isEqual:@(mb_method_version())] || ![meta[@"complete"] isEqual:@YES] ||
        !points.count || points.count>160) return NO;
    for (id point in points) { mb_result r; if (!MBDecodePoint(point,&r)) return NO; }
    return YES;
}
static NSString *SafeComment(id value) {
    return [[[value description] componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
}
NSString *MBCSV(NSDictionary *report) {
    NSMutableString *csv=[NSMutableString stringWithString:@"# Memory Benchmark for Mac\n# schema_version: 2\n"];
    NSDictionary *meta=report[@"metadata"];
    for (NSString *key in [[meta allKeys] sortedArrayUsingSelector:@selector(compare:)])
        [csv appendFormat:@"# %@: %@\n",key,SafeComment(meta[key])];
    [csv appendString:@"operation,buffer_bytes,unit,median,minimum,maximum,cv_percent,total_sample_seconds,iterations,samples,sample_1,sample_2,sample_3,sample_4,sample_5,sample_6,sample_7,sample_8,sample_9\n"];
    for (NSDictionary *point in report[@"points"]) {
        mb_result r; if (!MBDecodePoint(point,&r)) continue;
        [csv appendFormat:@"%s,%zu,%s,%.9f,%.9f,%.9f,%.6f,%.9f,%llu,%u",
            mb_operation_name(r.operation),r.bytes,mb_operation_unit(r.operation),mb_result_value(&r),
            mb_result_minimum(&r),mb_result_maximum(&r),r.cv_percent,r.seconds,(unsigned long long)r.passes,r.samples];
        for (unsigned i=0;i<MB_MAX_SAMPLES;++i) {
            if (i<r.samples) [csv appendFormat:@",%.9f",r.sample_values[i]]; else [csv appendString:@","];
        }
        [csv appendString:@"\n"];
    }
    return csv;
}
