#import "report.h"
#include <assert.h>
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
        mb_destroy(ctx); puts("PASS: JSON round trip, malformed reports, comparison compatibility, CSV units");
    }
}
