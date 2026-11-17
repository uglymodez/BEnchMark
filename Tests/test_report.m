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
            assert(fields.count==24);
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
        assert([MBCSV(ranges) containsString:@",4.000000000,,0,0,"]);
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
            assert(fields.count==24); ++csvCount;
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
        // Cache view restores read + code while keeping all five summary anchors.
        rangeMeta[@"mode"]=@"Cache Profile"; rangeMeta[@"sweep"]=@"cache-dense-v1";
        NSMutableArray *cachePoints=[NSMutableArray array];
        for (NSDictionary *record in densePoints) {
            mb_result value; assert(MBDecodePoint(record,&value));
            if (value.operation==MB_WRITE) value.operation=MB_EXECUTE;
            [cachePoints addObject:MBPointRecord(value)];
        }
        ranges[@"points"]=cachePoints; assert(MBValidReport(ranges));
        assert(MBRangeSummary(ranges).count==5 && MBRangeSummary(ranges)[0][@"execute_proxy"]);
        // Four block series: persist signed gaps and reject missing/duplicated coordinates.
        assert(mb_measure_blocks(ctx,MB_READ,4096,32,-128,.001,3,&r)==MB_OK);
        NSDictionary *blockPoint=MBPointRecord(r); assert(MBDecodePoint(blockPoint,&restored));
        assert(restored.block_bytes==32 && restored.access_gap_bytes==-128);
        for (id invalid in @[@16,@33,@(-1),@(1e20),NSNull.null]) {
            broken=[blockPoint mutableCopy]; broken[@"block_bytes"]=invalid; assert(!MBDecodePoint(broken,&restored));
        }
        broken=[blockPoint mutableCopy]; broken[@"access_gap_bytes"]=@0.5; assert(!MBDecodePoint(broken,&restored));
        NSMutableDictionary *blockMeta=[meta mutableCopy];
        blockMeta[@"mode"]=@"Read Blocks"; blockMeta[@"sweep"]=@"block-gap-v1";
        int gaps[MB_GAP_CAPACITY]; assert(mb_access_gaps(gaps,MB_GAP_CAPACITY)==47);
        NSMutableArray *blockPoints=[NSMutableArray array];
        for (unsigned i=0;i<MB_GAP_CAPACITY;++i) for (unsigned block=32;block<=256;block*=2) {
            double value=gaps[i]==0?10:20;
            mb_result sample={.bytes=4096,.operation=MB_READ,.block_bytes=block,.access_gap_bytes=gaps[i],
                .samples=3,.seconds=.003,.passes=30,.sample_values={value,value,value}};
            [blockPoints addObject:MBPointRecord(sample)];
        }
        NSMutableDictionary *blocks=[@{@"schema_version":@2,@"metadata":blockMeta,@"points":blockPoints} mutableCopy];
        assert(MBValidReport(blocks) && MBComparable(blockMeta,blockMeta));
        NSArray *blockSummary=MBBlockSummary(blocks); assert(blockSummary.count==4);
        for (NSDictionary *row in blockSummary) {
            assert([row[@"conditions"] unsignedIntegerValue]==47);
            assert([row[@"minimum"] doubleValue]==10 && [row[@"maximum"] doubleValue]==20 && [row[@"linear"] doubleValue]==10);
            assert(fabs([row[@"mean"] doubleValue]-930.0/47)<1e-9);
            assert(fabs([row[@"relative_speed_percent"] doubleValue]-9300.0/47)<1e-9); // >100 is legitimate
        }
        data=[NSJSONSerialization dataWithJSONObject:blocks options:0 error:nil];
        decoded=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        assert(MBValidReport(decoded) && [MBBlockSummary(decoded) isEqual:blockSummary]);
        assert([MBCSV(blocks) containsString:@"block_bytes,access_gap_bytes,accessed_bytes_per_pass"]);
        assert([MBCSV(blocks) containsString:@",32,-3072,64\n"]);
        blockMeta[@"complete"]=@NO; assert(!MBValidReport(blocks));
        for (NSDictionary *row in MBBlockSummary(blocks)) assert(!row[@"relative_speed_percent"]);
        blockMeta[@"complete"]=@YES;
        NSMutableArray *badPoints=[blockPoints mutableCopy]; badPoints[1]=badPoints[0];
        blocks[@"points"]=badPoints; assert(!MBValidReport(blocks));
        blocks[@"points"]=[blockPoints subarrayWithRange:NSMakeRange(0,187)]; assert(!MBValidReport(blocks));
        blocks[@"points"]=blockPoints; blockMeta[@"sweep"]=@"other"; assert(!MBValidReport(blocks));
        assert(!MBComparable(blockMeta,decoded[@"metadata"]));
        mb_destroy(ctx); puts("PASS: JSON round trip, malformed reports, comparison compatibility, CSV units");
    }
}


