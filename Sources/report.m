#import "report.h"
#include <math.h>
#include <string.h>

NSDictionary *MBPointRecord(mb_result r) {
    NSMutableArray *samples=[NSMutableArray array];
    for (unsigned i=0;i<r.samples;++i) [samples addObject:@(r.sample_values[i])];
    return @{@"operation_id":@(r.operation),@"block_bytes":@(r.block_bytes),@"access_gap_bytes":@(r.access_gap_bytes),@"operation":@(mb_operation_name(r.operation)),
        @"buffer_bytes":@(r.bytes),@"unit":@(mb_operation_unit(r.operation)),
        @"median":@(mb_result_value(&r)),@"minimum":@(mb_result_minimum(&r)),
        @"maximum":@(mb_result_maximum(&r)),@"mean":@(mb_result_mean(&r)),@"cv_percent":@(r.cv_percent),
        @"total_sample_seconds":@(r.seconds),@"iterations":@(r.passes),@"samples":@(r.samples),@"sample_values":samples};
}
static BOOL Number(id n) { return [n isKindOfClass:NSNumber.class] && isfinite([n doubleValue]); }
BOOL MBDecodePoint(id d, mb_result *out) {
    if (!out || ![d isKindOfClass:NSDictionary.class]) return NO;
    memset(out,0,sizeof(*out));
    for (NSString *key in @[@"operation_id",@"buffer_bytes",@"median",@"minimum",@"maximum",@"cv_percent",@"total_sample_seconds",@"iterations",@"samples"])
        if (!Number(d[key])) return NO;
    NSInteger op=[d[@"operation_id"] integerValue];
    double bytes=[d[@"buffer_bytes"] doubleValue], count=[d[@"samples"] doubleValue];
    if (op<MB_READ || op>MB_LATENCY || [d[@"operation_id"] doubleValue]!=op ||
        bytes<4096 || bytes>1024.*1024*1024 || fmod(bytes,256)!=0 ||
        (op==MB_EXECUTE && bytes>64.*1024*1024) || count<1 || count>MB_MAX_SAMPLES || floor(count)!=count ||
        [d[@"total_sample_seconds"] doubleValue]<=0 || [d[@"iterations"] doubleValue]<count ||
        [d[@"iterations"] doubleValue]>=0x1p64 || floor([d[@"iterations"] doubleValue])!=[d[@"iterations"] doubleValue]) return NO;
    if (![d[@"operation"] isEqual:@(mb_operation_name((mb_operation)op))]) return NO;
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
    if (d[@"block_bytes"] || d[@"access_gap_bytes"]) {
        if (!Number(d[@"block_bytes"]) || !Number(d[@"access_gap_bytes"])) return NO;
        double block=[d[@"block_bytes"] doubleValue], gap=[d[@"access_gap_bytes"] doubleValue];
        if (block!=0) {
            if (op>MB_WRITE || (block!=32 && block!=64 && block!=128 && block!=256) ||
                gap<-3072 || gap>7168 || fmod(gap,16)!=0) return NO;
            out->block_bytes=(unsigned)block; out->access_gap_bytes=(int)gap;
        } else if (gap!=0) return NO;
    }
    return YES;
}
BOOL MBComparable(NSDictionary *a, NSDictionary *b) {
    if (![a isKindOfClass:NSDictionary.class] || ![b isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in @[@"method",@"machine",@"mode",@"maximum_bytes",@"seconds_per_sample",@"samples",@"threads",@"low_power"])
        if (!a[key] || ![a[key] isEqual:b[key]]) return NO;
    if ([a[@"mode"] isEqual:@"Memory Ranges"] &&
        (![@[@"compact-5-v1",@"dense-16-v1"] containsObject:a[@"sweep"] ?: NSNull.null] || ![a[@"sweep"] isEqual:b[@"sweep"]])) return NO;
    if ([a[@"mode"] isEqual:@"Cache Profile"] || [@[@"Read Blocks",@"Write Blocks"] containsObject:a[@"mode"] ?: NSNull.null])
        if (!a[@"sweep"] || ![a[@"sweep"] isEqual:b[@"sweep"]]) return NO;
    return [b[@"complete"] isEqual:@YES] && ![a[@"power_changed"] isEqual:@YES] && ![b[@"power_changed"] isEqual:@YES];
}
BOOL MBValidReport(id report) {
    if (![report isKindOfClass:NSDictionary.class] || ![report[@"schema_version"] isEqual:@2] ||
        ![report[@"metadata"] isKindOfClass:NSDictionary.class] ||
        ![report[@"points"] isKindOfClass:NSArray.class]) return NO;
    NSDictionary *meta=report[@"metadata"]; NSArray *points=report[@"points"];
    if (![meta[@"method"] isEqual:@(mb_method_version())] || ![meta[@"complete"] isEqual:@YES] ||
        !points.count || points.count>2*MB_PROFILE_CAPACITY) return NO;
    NSArray *modes=@[@"Cache Speed",@"Read RAM",@"Write RAM",@"Latency",@"Memory Ranges",@"Cache Profile",@"Read Blocks",@"Write Blocks"];
    NSUInteger mode=[modes indexOfObject:meta[@"mode"] ?: NSNull.null];
    if (mode==NSNotFound || ![meta[@"machine"] isKindOfClass:NSString.class]) return NO;
    for (NSString *key in @[@"maximum_bytes",@"seconds_per_sample",@"samples",@"threads",@"low_power"])
        if (!Number(meta[key])) return NO;
    double maximum=[meta[@"maximum_bytes"] doubleValue], samples=[meta[@"samples"] doubleValue], seconds=[meta[@"seconds_per_sample"] doubleValue];
    if (maximum<4096 || maximum>1024.*1024*1024 || fmod(maximum,256)!=0 ||
        samples<1 || samples>MB_MAX_SAMPLES || floor(samples)!=samples || seconds<0.001 || seconds>1 ||
        ![meta[@"threads"] isEqual:@1] || (! [meta[@"low_power"] isEqual:@0] && ![meta[@"low_power"] isEqual:@1])) return NO;
    if (meta[@"power_changed"] && !Number(meta[@"power_changed"])) return NO;
    if (mode>=6) {
        int gaps[MB_GAP_CAPACITY]; size_t count=mb_access_gaps(gaps,MB_GAP_CAPACITY);
        if (![meta[@"sweep"] isEqual:@"block-gap-v1"] || points.count!=count*4) return NO;
        NSUInteger index=0;
        for (size_t i=0;i<count;++i) for (unsigned block=32;block<=256;block*=2) {
            mb_result r;
            if (!MBDecodePoint(points[index++],&r) || r.operation!=(mode==6?MB_READ:MB_WRITE) ||
                r.bytes!=(size_t)maximum || r.samples!=(unsigned)samples || r.block_bytes!=block || r.access_gap_bytes!=gaps[i]) return NO;
        }
        return YES;
    }
    BOOL cache=mode==5;
    if (cache && ![meta[@"sweep"] isEqual:@"cache-dense-v1"]) return NO;
    BOOL compact=mode==4;
    BOOL dense=compact && [meta[@"sweep"] isEqual:@"dense-16-v1"];
    if (compact && !dense && ![meta[@"sweep"] isEqual:@"compact-5-v1"]) return NO;
    size_t sizes[MB_PROFILE_CAPACITY], count=(dense || cache)?mb_profile_sizes((size_t)maximum,sizes,MB_PROFILE_CAPACITY):
        compact?mb_compact_sizes((size_t)maximum,sizes,MB_PROFILE_CAPACITY):mb_sizes((size_t)maximum,sizes,MB_PROFILE_CAPACITY);
    NSUInteger index=0;
    if (!count) return NO;
    for (size_t i=0;i<count;++i) {
        int operations=(compact || ((mode==0 || cache) && sizes[i]<=64*1024*1024))?2:1;
        for (int j=0;j<operations;++j) {
            mb_result r;
            mb_operation expected=j==1?(compact?MB_WRITE:MB_EXECUTE):mode==2?MB_WRITE:mode==3?MB_LATENCY:MB_READ;
            if (index>=points.count || !MBDecodePoint(points[index++],&r) || r.operation!=expected ||
                r.bytes!=sizes[i] || r.samples!=(unsigned)samples || r.block_bytes) return NO;
        }
    }
    if (index!=points.count) return NO;
    return YES;
}
NSArray<NSDictionary *> *MBRangeSummary(NSDictionary *report) {
    if (![report isKindOfClass:NSDictionary.class] || ![report[@"metadata"] isKindOfClass:NSDictionary.class] || ![report[@"points"] isKindOfClass:NSArray.class]) return @[];
    NSDictionary *meta=report[@"metadata"];
    BOOL cache=[meta[@"mode"] isEqual:@"Cache Profile"];
    if ((!cache && ![meta[@"mode"] isEqual:@"Memory Ranges"]) || !Number(meta[@"maximum_bytes"])) return @[];
    double maximum=[meta[@"maximum_bytes"] doubleValue];
    if (maximum<64.*1024*1024 || maximum>1024.*1024*1024 || fmod(maximum,256)) return @[];
    size_t sizes[5], count=mb_compact_sizes((size_t)maximum,sizes,5);
    NSMutableArray *rows=[NSMutableArray array];
    double best[3]={0,0,0};
    BOOL complete=MBValidReport(report);
    for (size_t i=0;i<count;++i) {
        NSMutableDictionary *row=[@{@"buffer_bytes":@(sizes[i])} mutableCopy];
        for (id point in report[@"points"]) {
            mb_result r;
            if (!MBDecodePoint(point,&r) || r.bytes!=sizes[i] || (r.operation!=(cache?MB_EXECUTE:MB_WRITE) && r.operation!=MB_READ)) continue;
            double mean=mb_result_mean(&r); best[r.operation]=fmax(best[r.operation],mean);
            row[@(mb_operation_name(r.operation))]=[@{@"minimum":@(r.minimum_gb_per_second),
                @"mean":@(mean),@"maximum":@(r.maximum_gb_per_second),@"unit":@"GB/s"} mutableCopy];
        }
        [rows addObject:row];
    }
    if (complete) for (NSMutableDictionary *row in rows) for (int op=MB_READ;op<=(cache?MB_EXECUTE:MB_WRITE);++op) {
        NSMutableDictionary *value=row[@(mb_operation_name((mb_operation)op))];
        if (value && best[op]>0) value[@"relative_speed_percent"]=@([value[@"mean"] doubleValue]/best[op]*100.0);
    }
    return rows;
}
NSArray<NSDictionary *> *MBBlockSummary(NSDictionary *report) {
    if (![report isKindOfClass:NSDictionary.class] || ![report[@"metadata"] isKindOfClass:NSDictionary.class] || ![report[@"points"] isKindOfClass:NSArray.class]) return @[];
    NSDictionary *meta=report[@"metadata"];
    if (![@[@"Read Blocks",@"Write Blocks"] containsObject:meta[@"mode"] ?: NSNull.null]) return @[];
    NSMutableArray *rows=[NSMutableArray array];
    BOOL complete=MBValidReport(report);
    for (unsigned block=32;block<=256;block*=2) {
        double minimum=INFINITY, maximum=0, sum=0, linear=0; NSUInteger count=0;
        for (id record in report[@"points"]) {
            mb_result r; if (!MBDecodePoint(record,&r) || r.block_bytes!=block) continue;
            double value=mb_result_value(&r); minimum=fmin(minimum,value); maximum=fmax(maximum,value); sum+=value; ++count;
            if (r.access_gap_bytes==0) linear=value;
        }
        NSMutableDictionary *row=[@{@"block_bytes":@(block),@"conditions":@(count)} mutableCopy];
        if (count) { row[@"minimum"]=@(minimum); row[@"maximum"]=@(maximum); row[@"mean"]=@(sum/count); }
        if (linear) row[@"linear"]=@(linear);
        if (complete && linear) row[@"relative_speed_percent"]=@(sum/count/linear*100);
        [rows addObject:row];
    }
    return rows;
}
static NSString *SafeComment(id value) {
    return [[[value description] componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
}
NSString *MBCSV(NSDictionary *report) {
    NSMutableString *csv=[NSMutableString stringWithString:@"# Memory Benchmark for Mac\n# schema_version: 2\n"];
    NSDictionary *meta=report[@"metadata"];
    for (NSString *key in [[meta allKeys] sortedArrayUsingSelector:@selector(compare:)])
        [csv appendFormat:@"# %@: %@\n",key,SafeComment(meta[key])];
    NSArray *summary=MBRangeSummary(report);
    if (summary.count) [csv appendString:@"# relative_speed_percent: mean / fastest mean of the same operation among the five summary buffers * 100, only after a complete sweep; blank for intermediate chart points; not cache hit rate\n"];
    [csv appendString:@"operation,buffer_bytes,unit,median,minimum,maximum,cv_percent,total_sample_seconds,iterations,samples,sample_1,sample_2,sample_3,sample_4,sample_5,sample_6,sample_7,sample_8,sample_9,mean,relative_speed_percent,block_bytes,access_gap_bytes,accessed_bytes_per_pass\n"];
    for (NSDictionary *point in report[@"points"]) {
        mb_result r; if (!MBDecodePoint(point,&r)) continue;
        [csv appendFormat:@"%s,%zu,%s,%.9f,%.9f,%.9f,%.6f,%.9f,%llu,%u",
            mb_operation_name(r.operation),r.bytes,mb_operation_unit(r.operation),mb_result_value(&r),
            mb_result_minimum(&r),mb_result_maximum(&r),r.cv_percent,r.seconds,(unsigned long long)r.passes,r.samples];
        for (unsigned i=0;i<MB_MAX_SAMPLES;++i) {
            if (i<r.samples) [csv appendFormat:@",%.9f",r.sample_values[i]]; else [csv appendString:@","];
        }
        [csv appendFormat:@",%.9f,",mb_result_mean(&r)];
        for (NSDictionary *row in summary) if ([row[@"buffer_bytes"] unsignedLongLongValue]==r.bytes) {
            NSNumber *percent=row[@(mb_operation_name(r.operation))][@"relative_speed_percent"];
            if (percent) [csv appendFormat:@"%.6f",percent.doubleValue];
        }
        [csv appendFormat:@",%u,%d,%zu\n",r.block_bytes,r.access_gap_bytes,r.block_bytes?mb_block_visits(r.bytes,r.block_bytes,r.access_gap_bytes)*r.block_bytes:r.bytes];
    }
    return csv;
}


