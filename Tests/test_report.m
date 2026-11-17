#import "report.h"
#include <assert.h>
#include <math.h>
int main(void) {
    @autoreleasepool {
        mb_context *ctx=mb_create(); assert(ctx); mb_result r, restored;
        assert(mb_measure(ctx,MB_LATENCY,4096,0.001,3,&r)==MB_OK);
        NSDictionary *point=MBPointRecord(r);
        NSData *data=[NSJSONSerialization dataWithJSONObject:point options:0 error:nil];
        assert(data); id decoded=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        assert(MBDecodePoint(decoded,&restored));
        assert(restored.nanoseconds_per_load==r.nanoseconds_per_load && restored.gb_per_second==0);
        assert(restored.cv_percent==r.cv_percent && restored.samples==3);
        assert(!MBDecodePoint(@[],&restored));
        NSMutableDictionary *broken=[point mutableCopy]; broken[@"sample_values"]=@[@1];
        assert(!MBDecodePoint(broken,&restored));
        broken=[point mutableCopy]; broken[@"operation_id"]=@99; assert(!MBDecodePoint(broken,&restored));
        broken=[point mutableCopy]; broken[@"unit"]=@"GB/s"; assert(!MBDecodePoint(broken,&restored));
        broken=[point mutableCopy]; broken[@"sample_values"]=@[@1,@0,@3]; assert(!MBDecodePoint(broken,&restored));
        NSDictionary *meta=@{@"method":@(mb_method_version()),@"machine":@"test",@"mode":@"Latency",@"maximum_bytes":@4096,@"seconds_per_sample":@0.001,@"samples":@3,@"threads":@1,@"low_power":@NO,@"complete":@YES};
        assert(MBComparable(meta,meta));
        for (NSString *key in @[@"method",@"machine",@"mode",@"maximum_bytes",@"seconds_per_sample",@"samples",@"threads",@"low_power",@"complete"]) {
            NSMutableDictionary *other=[meta mutableCopy]; [other removeObjectForKey:key];
            assert(!MBComparable(meta,other));
        }
        NSDictionary *report=@{@"schema_version":@2,@"metadata":meta,@"points":@[point]};
        assert(MBValidReport(report)); assert(!MBValidReport(@{})); assert(!MBValidReport(@"bad"));
        NSMutableDictionary *badReport=[report mutableCopy];
        badReport[@"points"]=@[point,point]; assert(!MBValidReport(badReport));
        badReport=[report mutableCopy]; NSMutableDictionary *badMeta=[meta mutableCopy];
        badMeta[@"maximum_bytes"]=@8192; badReport[@"metadata"]=badMeta; assert(!MBValidReport(badReport));
        badMeta[@"maximum_bytes"]=@4096; badMeta[@"power_changed"]=NSNull.null; assert(!MBValidReport(badReport));
        badMeta[@"power_changed"]=@YES; assert(!MBComparable(meta,badMeta));
        broken=[point mutableCopy]; broken[@"iterations"]=@(-1); assert(!MBDecodePoint(broken,&restored));
        broken[@"iterations"]=@(0x1p64); assert(!MBDecodePoint(broken,&restored));
        NSString *csv=MBCSV(report); assert([csv containsString:@"latency,4096,ns/load,"]);
        assert([csv containsString:@"sample_9"]);
        // Different fastest buffers for reading and writing; mean != median.
        NSMutableDictionary *rangeMeta=[meta mutableCopy];
        rangeMeta[@"mode"]=@"Memory Ranges"; rangeMeta[@"sweep"]=@"compact-5-v1";
        rangeMeta[@"maximum_bytes"]=@(64*1024*1024);
        size_t sizes[5]; assert(mb_compact_sizes(64*1024*1024,sizes,5)==5);
        NSMutableArray *rangePoints=[NSMutableArray array];
        for (unsigned i=0;i<5;++i) for (int op=0;op<2;++op) {
            double scale=op==MB_READ?i+1:10-i;
            mb_result value={.bytes=sizes[i],.operation=(mb_operation)op,.samples=3,.seconds=.01,.passes=30,
                .sample_values={scale,2*scale,9*scale}};
            [rangePoints addObject:MBPointRecord(value)];
        }
        NSMutableDictionary *ranges=[@{@"schema_version":@2,@"metadata":rangeMeta,@"points":rangePoints} mutableCopy];
        assert(MBValidReport(ranges)); assert(MBComparable(rangeMeta,rangeMeta));
        assert(!MBComparable(meta,rangeMeta));
        NSArray *summary=MBRangeSummary(ranges); assert(summary.count==5);
        for (unsigned i=0;i<5;++i) {
            NSDictionary *read=summary[i][@"read"], *write=summary[i][@"write"];
            assert([read[@"mean"] doubleValue]==4*(i+1));
            assert([read[@"minimum"] doubleValue]==i+1 && [read[@"maximum"] doubleValue]==9*(i+1));
            assert(fabs([read[@"relative_speed_percent"] doubleValue]-20*(i+1))<1e-9);
            assert(fabs([write[@"relative_speed_percent"] doubleValue]-(10-i)*10)<1e-9);
        }
        NSString *rangesCSV=MBCSV(ranges);
        NSArray *lines=[rangesCSV componentsSeparatedByString:@"\n"];
        NSUInteger row=0;
        for (NSString *line in lines) if ([line hasPrefix:@"read,"] || [line hasPrefix:@"write,"]) {
            NSArray *fields=[line componentsSeparatedByString:@","];
            assert(fields.count==50);
            NSString *op=fields[0]; NSDictionary *value=summary[row/2][op];
            assert(fabs([fields[19] doubleValue]-[value[@"mean"] doubleValue])<1e-8);
            assert(fabs([fields[20] doubleValue]-[value[@"relative_speed_percent"] doubleValue])<1e-5);
            ++row;
        }
        assert(row==10);
        ranges[@"range_summary"]=summary;
        NSData *rangeJSON=[NSJSONSerialization dataWithJSONObject:ranges options:0 error:nil];
        NSDictionary *roundtrip=[NSJSONSerialization JSONObjectWithData:rangeJSON options:0 error:nil];
        assert([MBRangeSummary(roundtrip) isEqual:summary]);
        // Never trust persisted mean or normalize an incomplete run.
        NSMutableDictionary *forged=[rangePoints[0] mutableCopy]; forged[@"mean"]=@999;
        assert(MBDecodePoint(forged,&restored) && mb_result_mean(&restored)==4);
        rangeMeta[@"complete"]=@NO; assert(!MBValidReport(ranges));
        for (NSDictionary *entry in MBRangeSummary(ranges)) assert(!entry[@"read"][@"relative_speed_percent"]);
        assert([MBCSV(ranges) containsString:@",4.000000000,,0,0,,false,"]);
        rangeMeta[@"complete"]=@YES;
        ranges[@"points"]=[rangePoints subarrayWithRange:NSMakeRange(0,9)]; assert(!MBValidReport(ranges));
        for (NSDictionary *entry in MBRangeSummary(ranges)) assert(!entry[@"write"][@"relative_speed_percent"]);
        NSMutableArray *duplicates=[rangePoints mutableCopy]; duplicates[1]=duplicates[0];
        ranges[@"points"]=duplicates; assert(!MBValidReport(ranges));
        ranges[@"points"]=rangePoints; rangeMeta[@"sweep"]=@"wrong"; assert(!MBValidReport(ranges));
        assert(!MBComparable(rangeMeta,rangeMeta));
        assert(MBRangeSummary(@{}).count==0);
        // Dense chart has every intermediate read/write pair but the summary
        // remains five reference buffers. Intermediate peaks do not redefine %.
        rangeMeta[@"sweep"]=@"compact-5-v1";
        NSDictionary *oldMeta=[rangeMeta copy];
        rangeMeta[@"sweep"]=@"dense-16-v1";
        assert(!MBComparable(rangeMeta,oldMeta)); assert(!MBComparable(oldMeta,rangeMeta));
        size_t denseSizes[MB_PROFILE_CAPACITY];
        size_t denseCount=mb_profile_sizes(64*1024*1024,denseSizes,MB_PROFILE_CAPACITY);
        NSMutableArray *densePoints=[NSMutableArray array];
        for (size_t i=0;i<denseCount;++i) for (int op=0;op<2;++op) {
            NSDictionary *anchor=nil;
            for (NSDictionary *p in rangePoints) if ([p[@"buffer_bytes"] unsignedLongLongValue]==denseSizes[i] && [p[@"operation_id"] intValue]==op) anchor=p;
            mb_result intermediate={.bytes=denseSizes[i],.operation=(mb_operation)op,.samples=3,.seconds=.01,.passes=30,.sample_values={900,1000,1100}};
            [densePoints addObject:anchor ?: MBPointRecord(intermediate)];
        }
        ranges[@"points"]=densePoints;
        assert(densePoints.count==450 && MBValidReport(ranges));
        assert(MBComparable(rangeMeta,rangeMeta));
        assert([MBRangeSummary(ranges) isEqual:summary]);
        NSUInteger csvCount=0, percentCount=0;
        for (NSString *line in [MBCSV(ranges) componentsSeparatedByString:@"\n"]) if ([line hasPrefix:@"read,"] || [line hasPrefix:@"write,"]) {
            NSArray *fields=[line componentsSeparatedByString:@","];
            assert(fields.count==50); ++csvCount;
            if ([fields[20] length]) ++percentCount;
            else assert([fields[19] doubleValue]==1000);
        }
        assert(csvCount==450 && percentCount==10);
        rangeMeta[@"complete"]=@NO;
        for (NSDictionary *entry in MBRangeSummary(ranges)) assert(!entry[@"read"][@"relative_speed_percent"]);
        rangeMeta[@"complete"]=@YES;
        NSMutableArray *missing=[densePoints mutableCopy]; [missing removeObjectAtIndex:3];
        ranges[@"points"]=missing; assert(!MBValidReport(ranges));
        ranges[@"points"]=rangePoints; assert(!MBValidReport(ranges)); // sparse data cannot masquerade as dense
        ranges[@"points"]=densePoints; rangeMeta[@"sweep"]=@"compact-5-v1"; assert(!MBValidReport(ranges));
        NSMutableDictionary *blockMeta=[meta mutableCopy];
        blockMeta[@"mode"]=@"Read RAM"; blockMeta[@"sweep"]=@"block-stride-v1"; blockMeta[@"maximum_bytes"]=@65536;
        NSMutableArray *blockPoints=[NSMutableArray array];
        for (size_t block=32;block<=256;block*=2) for (unsigned i=0;i<=MB_BLOCK_STEPS;++i) {
            mb_result v={.bytes=65536,.block_bytes=block,.stride_bytes=i?1024+(i-1)*256:block,
                .operation=MB_READ,.samples=3,.seconds=.01,.passes=30,.sample_values={1,2,9}};
            if (!i) { v.sample_values[0]=2; v.sample_values[1]=2; v.sample_values[2]=2; }
            [blockPoints addObject:MBPointRecord(v)];
        }
        NSMutableDictionary *blockReport=[@{@"schema_version":@2,@"metadata":blockMeta,@"points":blockPoints} mutableCopy];
        assert(MBValidReport(blockReport)); assert(MBComparable(blockMeta,blockMeta));
        NSArray *blockSummary=MBBlockSummary(blockReport); assert(blockSummary.count==4);
        for (NSDictionary *row in blockSummary) {
            assert([row[@"minimum"] doubleValue]==1 && [row[@"maximum"] doubleValue]==9);
            assert([row[@"mean"] doubleValue]==4 && [row[@"linear"] doubleValue]==2);
            assert([row[@"efficiency_percent"] doubleValue]==200); // Not clamped to 100%.
        }
        assert([MBCSV(blockReport) containsString:@",32,1024,-3072,false"]);
        assert([MBCSV(blockReport) containsString:@",32,32,,true"]);
        blockMeta[@"complete"]=@NO;
        for (NSDictionary *row in MBBlockSummary(blockReport)) assert(!row[@"efficiency_percent"]);
        blockMeta[@"complete"]=@YES;
        blockReport[@"points"]=[blockPoints subarrayWithRange:NSMakeRange(0,167)]; assert(!MBValidReport(blockReport));
        blockReport[@"points"]=blockPoints;
        NSMutableDictionary *legacy=[blockMeta mutableCopy]; [legacy removeObjectForKey:@"sweep"];
        assert(!MBComparable(blockMeta,legacy) && !MBComparable(legacy,blockMeta));
        NSMutableDictionary *invalid=[blockPoints[1] mutableCopy]; invalid[@"stride_bytes"]=@1001;
        assert(!MBDecodePoint(invalid,&restored));
        // Real clock/counter evidence survives JSON, and tampering is rejected.
        assert(MBDecodePoint(point,&restored) && restored.work_units_per_iteration==1);
        assert(restored.sample_seconds[0]>0 && restored.sample_iterations[0]>0);
        NSMutableDictionary *auditMeta=[meta mutableCopy]; auditMeta[@"measurement_protocol"]=@"timing-audit-v1";
        NSDictionary *auditReport=@{@"schema_version":@2,@"metadata":auditMeta,@"points":@[point]};
        assert(MBValidReport(auditReport)); assert(!MBComparable(auditMeta,meta));
        assert([MBTimingDescription(auditReport) containsString:@"ns/load"]);
        NSMutableDictionary *tampered=[point mutableCopy];
        NSMutableArray *times=[point[@"sample_seconds"] mutableCopy]; times[0]=@([times[0] doubleValue]*2);
        tampered[@"sample_seconds"]=times; assert(!MBDecodePoint(tampered,&restored));
        tampered=[point mutableCopy]; tampered[@"work_units_per_iteration"]=@2; assert(!MBDecodePoint(tampered,&restored));
        tampered=[point mutableCopy]; tampered[@"iterations"]=@([point[@"iterations"] unsignedLongLongValue]+1); assert(!MBDecodePoint(tampered,&restored));
        tampered=[point mutableCopy];
        for (NSString *key in @[@"sample_seconds",@"sample_iterations",@"work_units_per_iteration",@"work_unit"]) [tampered removeObjectForKey:key];
        assert(MBDecodePoint(tampered,&restored)); // legacy point still readable, not an audited report
        assert(!MBValidReport(@{@"schema_version":@2,@"metadata":auditMeta,@"points":@[tampered]}));
        assert(mb_measure_blocks(ctx,MB_READ,65536,64,4096,.001,3,&r)==MB_OK);
        NSDictionary *blockAudit=MBPointRecord(r); assert(MBDecodePoint(blockAudit,&restored));
        assert(restored.work_units_per_iteration==1024);
        mb_destroy(ctx); puts("PASS: JSON round trip, malformed reports, comparison compatibility, CSV units");
    }
}

