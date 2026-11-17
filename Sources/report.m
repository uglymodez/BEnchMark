#import "report.h"
#include <math.h>
#include <string.h>

NSDictionary *MBPointRecord(mb_result r) {
    NSMutableArray *samples=[NSMutableArray array];
    for (unsigned i=0;i<r.samples;++i) [samples addObject:@(r.sample_values[i])];
    NSMutableDictionary *record=[@{@"operation_id":@(r.operation),@"operation":@(mb_operation_name(r.operation)),
        @"buffer_bytes":@(r.bytes),@"block_bytes":@(r.block_bytes),@"stride_bytes":@(r.stride_bytes),@"unit":@(mb_operation_unit(r.operation)),
        @"median":@(mb_result_value(&r)),@"minimum":@(mb_result_minimum(&r)),
        @"maximum":@(mb_result_maximum(&r)),@"mean":@(mb_result_mean(&r)),@"cv_percent":@(r.cv_percent),
        @"total_sample_seconds":@(r.seconds),@"iterations":@(r.passes),@"samples":@(r.samples),@"sample_values":samples} mutableCopy];
    if (r.work_units_per_iteration) {
        NSMutableArray *seconds=[NSMutableArray array], *iterations=[NSMutableArray array];
        for (unsigned i=0;i<r.samples;++i) { [seconds addObject:@(r.sample_seconds[i])]; [iterations addObject:@(r.sample_iterations[i])]; }
        record[@"sample_seconds"]=seconds; record[@"sample_iterations"]=iterations;
        record[@"work_units_per_iteration"]=@(r.work_units_per_iteration);
        record[@"work_unit"]=r.operation==MB_LATENCY?@"loads":@"bytes";
    }
    return record;
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
    if (d[@"block_bytes"] || d[@"stride_bytes"]) {
        if (!Number(d[@"block_bytes"]) || !Number(d[@"stride_bytes"])) return NO;
        double block=[d[@"block_bytes"] doubleValue], stride=[d[@"stride_bytes"] doubleValue];
        if (block || stride) {
            if ((op!=MB_READ && op!=MB_WRITE) || bytes<16384 ||
                (block!=32 && block!=64 && block!=128 && block!=256) ||
                (stride!=block && (stride<1024 || stride>11264 || fmod(stride,256)))) return NO;
            out->block_bytes=(size_t)block; out->stride_bytes=(size_t)stride;
        }
    }
    if (d[@"sample_seconds"] || d[@"sample_iterations"] || d[@"work_units_per_iteration"] || d[@"work_unit"]) {
        NSArray *times=d[@"sample_seconds"], *iterations=d[@"sample_iterations"];
        uint64_t units=out->block_bytes?((out->bytes-out->block_bytes)/out->stride_bytes+1)*out->block_bytes:op==MB_LATENCY?1:out->bytes;
        if (![times isKindOfClass:NSArray.class] || ![iterations isKindOfClass:NSArray.class] ||
            times.count!=(NSUInteger)count || iterations.count!=(NSUInteger)count ||
            !Number(d[@"work_units_per_iteration"]) || [d[@"work_units_per_iteration"] doubleValue]!=(double)units ||
            ![d[@"work_unit"] isEqual:op==MB_LATENCY?@"loads":@"bytes"]) return NO;
        double totalSeconds=0; uint64_t totalIterations=0;
        for (unsigned i=0;i<(unsigned)count;++i) {
            if (!Number(times[i]) || [times[i] doubleValue]<=0 || !Number(iterations[i])) return NO;
            double n=[iterations[i] doubleValue], seconds=[times[i] doubleValue];
            if (n<1 || n>=0x1p64 || floor(n)!=n) return NO;
            uint64_t passes=[iterations[i] unsignedLongLongValue];
            if (UINT64_MAX-totalIterations<passes) return NO;
            double rate=op==MB_LATENCY?seconds*1e9/n:(double)units*n/seconds/1e9;
            if (!isfinite(rate) || fabs(rate-out->sample_values[i])>1e-9*fmax(1,rate)) return NO;
            out->sample_seconds[i]=seconds; out->sample_iterations[i]=passes;
            totalSeconds+=seconds; totalIterations+=passes;
        }
        if (totalIterations!=out->passes || fabs(totalSeconds-out->seconds)>1e-9*fmax(1,totalSeconds)) return NO;
        out->work_units_per_iteration=units;
    }
    return YES;
}
BOOL MBComparable(NSDictionary *a, NSDictionary *b) {
    if (![a isKindOfClass:NSDictionary.class] || ![b isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in @[@"method",@"machine",@"mode",@"maximum_bytes",@"seconds_per_sample",@"samples",@"threads",@"low_power"])
        if (!a[key] || ![a[key] isEqual:b[key]]) return NO;
    if ([a[@"mode"] isEqual:@"Memory Ranges"] &&
        (![@[@"compact-5-v1",@"dense-16-v1"] containsObject:a[@"sweep"] ?: NSNull.null] || ![a[@"sweep"] isEqual:b[@"sweep"]])) return NO;
    if ((a[@"sweep"] || b[@"sweep"]) && ![a[@"sweep"] isEqual:b[@"sweep"]]) return NO;
    if ((a[@"measurement_protocol"] || b[@"measurement_protocol"]) &&
        ![a[@"measurement_protocol"] isEqual:b[@"measurement_protocol"]]) return NO;
    return [b[@"complete"] isEqual:@YES] && ![a[@"power_changed"] isEqual:@YES] && ![b[@"power_changed"] isEqual:@YES];
}
BOOL MBValidReport(id report) {
    if (![report isKindOfClass:NSDictionary.class] || ![report[@"schema_version"] isEqual:@2] ||
        ![report[@"metadata"] isKindOfClass:NSDictionary.class] ||
        ![report[@"points"] isKindOfClass:NSArray.class]) return NO;
    NSDictionary *meta=report[@"metadata"]; NSArray *points=report[@"points"];
    if (![meta[@"method"] isEqual:@(mb_method_version())] || ![meta[@"complete"] isEqual:@YES] ||
        !points.count || points.count>2*MB_PROFILE_CAPACITY) return NO;
    NSArray *modes=@[@"Cache Speed",@"Read RAM",@"Write RAM",@"Latency",@"Memory Ranges"];
    NSUInteger mode=[modes indexOfObject:meta[@"mode"] ?: NSNull.null];
    if (mode==NSNotFound || ![meta[@"machine"] isKindOfClass:NSString.class]) return NO;
    for (NSString *key in @[@"maximum_bytes",@"seconds_per_sample",@"samples",@"threads",@"low_power"])
        if (!Number(meta[key])) return NO;
    double maximum=[meta[@"maximum_bytes"] doubleValue], samples=[meta[@"samples"] doubleValue], seconds=[meta[@"seconds_per_sample"] doubleValue];
    if (maximum<4096 || maximum>1024.*1024*1024 || fmod(maximum,256)!=0 ||
        samples<1 || samples>MB_MAX_SAMPLES || floor(samples)!=samples || seconds<0.001 || seconds>1 ||
        ![meta[@"threads"] isEqual:@1] || (! [meta[@"low_power"] isEqual:@0] && ![meta[@"low_power"] isEqual:@1])) return NO;
    if (meta[@"measurement_protocol"]) {
        if (![meta[@"measurement_protocol"] isEqual:@"timing-audit-v1"]) return NO;
        for (id point in points) {
            mb_result r; if (!MBDecodePoint(point,&r) || !r.work_units_per_iteration) return NO;
        }
    }
    if (meta[@"power_changed"] && !Number(meta[@"power_changed"])) return NO;
    if ([meta[@"sweep"] isEqual:@"block-stride-v1"]) {
        if ((mode!=1 && mode!=2) || maximum<16384 || points.count!=4*(MB_BLOCK_STEPS+1)) return NO;
        NSUInteger index=0;
        for (size_t block=32;block<=256;block*=2) for (unsigned step=0;step<=MB_BLOCK_STEPS;++step) {
            mb_result r; size_t stride=step==0?block:1024+(step-1)*256;
            if (!MBDecodePoint(points[index++],&r) || r.block_bytes!=block || r.stride_bytes!=stride ||
                r.bytes!=(size_t)maximum || r.samples!=(unsigned)samples || r.operation!=(mode==1?MB_READ:MB_WRITE)) return NO;
        }
        return YES;
    }
    BOOL compact=mode==4;
    BOOL dense=compact && [meta[@"sweep"] isEqual:@"dense-16-v1"];
    if (compact && !dense && ![meta[@"sweep"] isEqual:@"compact-5-v1"]) return NO;
    size_t sizes[MB_PROFILE_CAPACITY], count=dense?mb_profile_sizes((size_t)maximum,sizes,MB_PROFILE_CAPACITY):
        compact?mb_compact_sizes((size_t)maximum,sizes,MB_PROFILE_CAPACITY):mb_sizes((size_t)maximum,sizes,MB_PROFILE_CAPACITY);
    NSUInteger index=0;
    if (!count) return NO;
    for (size_t i=0;i<count;++i) {
        int operations=(compact || (mode==0 && sizes[i]<=64*1024*1024))?2:1;
        for (int j=0;j<operations;++j) {
            mb_result r;
            mb_operation expected=j==1?(compact?MB_WRITE:MB_EXECUTE):mode==2?MB_WRITE:mode==3?MB_LATENCY:MB_READ;
            if (index>=points.count || !MBDecodePoint(points[index++],&r) || r.operation!=expected ||
                r.block_bytes || r.stride_bytes || r.bytes!=sizes[i] || r.samples!=(unsigned)samples) return NO;
        }
    }
    if (index!=points.count) return NO;
    return YES;
}
NSArray<NSDictionary *> *MBRangeSummary(NSDictionary *report) {
    if (![report isKindOfClass:NSDictionary.class] || ![report[@"metadata"] isKindOfClass:NSDictionary.class] || ![report[@"points"] isKindOfClass:NSArray.class]) return @[];
    NSDictionary *meta=report[@"metadata"];
    if (![meta[@"mode"] isEqual:@"Memory Ranges"] || !Number(meta[@"maximum_bytes"])) return @[];
    double maximum=[meta[@"maximum_bytes"] doubleValue];
    if (maximum<64.*1024*1024 || maximum>1024.*1024*1024 || fmod(maximum,256)) return @[];
    size_t sizes[5], count=mb_compact_sizes((size_t)maximum,sizes,5);
    NSMutableArray *rows=[NSMutableArray array];
    double best[2]={0,0};
    BOOL complete=MBValidReport(report);
    for (size_t i=0;i<count;++i) {
        NSMutableDictionary *row=[@{@"buffer_bytes":@(sizes[i])} mutableCopy];
        for (id point in report[@"points"]) {
            mb_result r;
            if (!MBDecodePoint(point,&r) || r.bytes!=sizes[i] || r.operation>MB_WRITE) continue;
            double mean=mb_result_mean(&r); best[r.operation]=fmax(best[r.operation],mean);
            row[@(mb_operation_name(r.operation))]=[@{@"minimum":@(r.minimum_gb_per_second),
                @"mean":@(mean),@"maximum":@(r.maximum_gb_per_second),@"unit":@"GB/s"} mutableCopy];
        }
        [rows addObject:row];
    }
    if (complete) for (NSMutableDictionary *row in rows) for (int op=MB_READ;op<=MB_WRITE;++op) {
        NSMutableDictionary *value=row[@(mb_operation_name((mb_operation)op))];
        if (value && best[op]>0) value[@"relative_speed_percent"]=@([value[@"mean"] doubleValue]/best[op]*100.0);
    }
    return rows;
}
NSArray<NSDictionary *> *MBBlockSummary(NSDictionary *report) {
    if (![report isKindOfClass:NSDictionary.class] || ![report[@"metadata"] isKindOfClass:NSDictionary.class] || ![report[@"points"] isKindOfClass:NSArray.class]) return @[];
    if (![report[@"metadata"][@"sweep"] isEqual:@"block-stride-v1"]) return @[];
    NSMutableArray *rows=[NSMutableArray array]; BOOL complete=MBValidReport(report);
    for (size_t block=32;block<=256;block*=2) {
        double minimum=INFINITY, maximum=0, sum=0, linear=0; unsigned count=0;
        for (id point in report[@"points"]) {
            mb_result r; if (!MBDecodePoint(point,&r) || r.block_bytes!=block) continue;
            if (r.stride_bytes==block) { linear=mb_result_mean(&r); continue; }
            minimum=fmin(minimum,r.minimum_gb_per_second); maximum=fmax(maximum,r.maximum_gb_per_second);
            sum+=mb_result_mean(&r); ++count;
        }
        NSMutableDictionary *row=[@{@"block_bytes":@(block),@"measured_steps":@(count),@"unit":@"GB/s"} mutableCopy];
        if (linear>0) row[@"linear"]=@(linear);
        if (count) { row[@"minimum"]=@(minimum); row[@"maximum"]=@(maximum); row[@"mean"]=@(sum/count); }
        if (complete && linear>0 && count==MB_BLOCK_STEPS) row[@"efficiency_percent"]=@(sum/count/linear*100);
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
    NSArray *summary=MBRangeSummary(report), *blocks=MBBlockSummary(report);
    if (summary.count) [csv appendString:@"# relative_speed_percent: mean / fastest mean of the same operation among the five summary buffers * 100, only after a complete sweep; blank for intermediate chart points; not cache hit rate\n"];
    [csv appendString:@"operation,buffer_bytes,unit,median,minimum,maximum,cv_percent,total_sample_seconds,iterations,samples,sample_1,sample_2,sample_3,sample_4,sample_5,sample_6,sample_7,sample_8,sample_9,mean,relative_speed_percent,block_bytes,stride_bytes,offset_bytes,linear_reference,block_minimum,block_maximum,block_mean,linear_gb_per_second,efficiency_percent,work_units_per_iteration,work_unit"];
    for (unsigned i=1;i<=MB_MAX_SAMPLES;++i) [csv appendFormat:@",sample_%u_seconds,sample_%u_iterations",i,i];
    [csv appendString:@"\n"];
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
        [csv appendFormat:@",%zu,%zu,",r.block_bytes,r.stride_bytes];
        if (r.block_bytes && r.stride_bytes!=r.block_bytes) [csv appendFormat:@"%ld",(long)r.stride_bytes-4096];
        [csv appendFormat:@",%@",r.block_bytes && r.stride_bytes==r.block_bytes?@"true":@"false"];
        NSDictionary *blockRow=nil;
        for (NSDictionary *row in blocks) if ([row[@"block_bytes"] unsignedLongLongValue]==r.block_bytes) blockRow=row;
        for (NSString *key in @[@"minimum",@"maximum",@"mean",@"linear",@"efficiency_percent"]) {
            [csv appendString:@","]; if (blockRow[key]) [csv appendFormat:@"%.9f",[blockRow[key] doubleValue]];
        }
        [csv appendString:@","]; if (r.work_units_per_iteration) [csv appendFormat:@"%llu",(unsigned long long)r.work_units_per_iteration];
        [csv appendFormat:@",%@",r.work_units_per_iteration?(r.operation==MB_LATENCY?@"loads":@"bytes"):@""];
        for (unsigned i=0;i<MB_MAX_SAMPLES;++i) {
            if (r.work_units_per_iteration && i<r.samples) [csv appendFormat:@",%.17g,%llu",r.sample_seconds[i],(unsigned long long)r.sample_iterations[i]];
            else [csv appendString:@",,"];
        }
        [csv appendString:@"\n"];
    }
    return csv;
}


NSString *MBTimingDescription(NSDictionary *report) {
    NSMutableString *text=[NSMutableString stringWithFormat:@"Исходные измерения · %@\n%@\nПрогон: %@\n\n",report[@"metadata"][@"mode"] ?: @"",report[@"metadata"][@"machine"] ?: @"",report[@"metadata"][@"run_id"] ?: @"—"];
    [text appendString:@"Каждый повтор: полезный объём / фактически прошедшее время. Подготовка и отрисовка не входят в таймер. Внешние процессы всё равно могут влиять на результат.\n\n"];
    for (id record in report[@"points"]) {
        mb_result r; if (!MBDecodePoint(record,&r)) continue;
        [text appendFormat:@"%s · буфер %zu байт",mb_operation_name(r.operation),r.bytes];
        if (r.block_bytes) [text appendFormat:@" · блок %zu · шаг %zu%@",r.block_bytes,r.stride_bytes,r.block_bytes==r.stride_bytes?@" (линейный)":@""];
        [text appendFormat:@"\nСреднее %.6f · медиана %.6f %s · min–max %.6f–%.6f · CV %.2f%%\n",mb_result_mean(&r),mb_result_value(&r),mb_operation_unit(r.operation),mb_result_minimum(&r),mb_result_maximum(&r),r.cv_percent];
        if (!r.work_units_per_iteration) { [text appendString:@"В старом отчёте нет времени по отдельным повторам.\n\n"]; continue; }
        for (unsigned i=0;i<r.samples;++i) {
            if (r.operation==MB_LATENCY) [text appendFormat:@"%u: %.9f с × 10⁹ / %llu чтений = %.6f ns/load\n",i+1,r.sample_seconds[i],(unsigned long long)r.sample_iterations[i],r.sample_values[i]];
            else [text appendFormat:@"%u: %llu байт × %llu проходов / %.9f с / 10⁹ = %.6f GB/s\n",i+1,(unsigned long long)r.work_units_per_iteration,(unsigned long long)r.sample_iterations[i],r.sample_seconds[i],r.sample_values[i]];
        }
        [text appendString:@"\n"];
    }
    return text;
}
