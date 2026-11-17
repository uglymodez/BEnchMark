#define _POSIX_C_SOURCE 200809L
#include "benchmark.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <time.h>

static void verify_timing(mb_result r) {
    assert(r.work_units_per_iteration>0);
    uint64_t iterations=0; double seconds=0;
    for (unsigned i=0;i<r.samples;++i) {
        assert(r.sample_seconds[i]>0 && r.sample_iterations[i]>0);
        double expected=r.operation==MB_LATENCY?r.sample_seconds[i]*1e9/r.sample_iterations[i]:
            (double)r.work_units_per_iteration*r.sample_iterations[i]/r.sample_seconds[i]/1e9;
        assert(fabs(expected-r.sample_values[i])<1e-9*fmax(1,expected));
        iterations+=r.sample_iterations[i]; seconds+=r.sample_seconds[i];
    }
    assert(iterations==r.passes && seconds==r.seconds);
}
static void *cancel_later(void *p) {
    struct timespec delay={0,20000000}; nanosleep(&delay,NULL); mb_cancel(p); return NULL;
}
int main(void) {
    size_t sizes[80];
    size_t count=mb_sizes(64*1024*1024,sizes,80);
    assert(count==57 && sizes[0]==4096 && sizes[count-1]==64*1024*1024);
    for (size_t i=1; i<count; ++i) assert(sizes[i]>sizes[i-1] && sizes[i]%256==0);
    assert(mb_sizes(4096,sizes,80)==1);
    assert(mb_sizes(1024,sizes,80)==0);
    assert(mb_sizes(1024*1024,sizes,2)==0);
    count=mb_sizes(1024UL*1024*1024,sizes,80); assert(count==73);
    assert(mb_sizes(65536+256,sizes,80)==18);
    for (size_t maximum=64UL*1024*1024;maximum<=1024UL*1024*1024;maximum*=2) {
        assert(mb_compact_sizes(maximum,sizes,80)==5);
        assert(sizes[0]==4096 && sizes[1]==65536 && sizes[2]==1024*1024 && sizes[3]==16*1024*1024 && sizes[4]==maximum);
        for (size_t i=1;i<5;++i) assert(sizes[i]>sizes[i-1]);
    }
    assert(mb_compact_sizes(32*1024*1024,sizes,80)==0);
    assert(mb_compact_sizes(64*1024*1024,sizes,4)==0);
    assert(mb_compact_sizes(64*1024*1024,NULL,80)==0);
    mb_result asymmetric={.samples=3,.sample_values={1,2,9}};
    assert(mb_result_mean(&asymmetric)==4);
    assert(mb_result_mean(NULL)==0);
    size_t detailed[MB_PROFILE_CAPACITY], anchors[5];
    for (size_t maximum=64UL*1024*1024;maximum<=1024UL*1024*1024;maximum*=2) {
        size_t count=mb_profile_sizes(maximum,detailed,MB_PROFILE_CAPACITY);
        assert(count==225+16*(size_t)log2((double)maximum/(64*1024*1024)));
        assert(detailed[0]==4096 && detailed[count-1]==maximum);
        for (size_t i=1;i<count;++i) {
            assert(detailed[i]>detailed[i-1] && detailed[i]%256==0);
            assert(detailed[i]-detailed[i-1]<=detailed[i-1]/16);
        }
        assert(mb_compact_sizes(maximum,anchors,5)==5);
        for (unsigned a=0;a<5;++a) {
            unsigned matches=0;
            for (size_t i=0;i<count;++i) matches+=detailed[i]==anchors[a];
            assert(matches==1);
        }
        assert(mb_profile_sizes(maximum,detailed,count-1)==0);
    }
    assert(mb_profile_sizes(64*1024*1024,NULL,MB_PROFILE_CAPACITY)==0);
    assert(mb_profile_sizes(16*1024*1024,detailed,MB_PROFILE_CAPACITY)==0);
    assert(mb_profile_sizes(64*1024*1024+1,detailed,MB_PROFILE_CAPACITY)==0);
    assert(mb_profile_sizes(64*1024*1024+256,detailed,MB_PROFILE_CAPACITY)==226);
    mb_context *ctx=mb_create(); assert(ctx);
    mb_result r;
    assert(mb_measure(ctx,MB_READ,4097,0.002,3,&r)==MB_ERROR);
    assert(mb_measure(ctx,MB_READ,4096,NAN,3,&r)==MB_ERROR);
    assert(mb_measure(ctx,MB_READ,4096,0.002,0,&r)==MB_ERROR);
    assert(mb_measure(ctx,MB_EXECUTE,128*1024*1024,0.002,3,&r)==MB_UNAVAILABLE);
    for (int op=MB_READ; op<=MB_LATENCY; ++op) {
        for (size_t n=4096; n<=1024*1024; n*=16) {
            mb_status status=mb_measure(ctx,(mb_operation)op,n,0.002,3,&r);
            if (op==MB_EXECUTE && status==MB_UNAVAILABLE) {
                fprintf(stderr,"SKIP execute: %s\n",mb_error(ctx)); break;
            }
            assert(status==MB_OK);
            verify_timing(r);
            assert(r.bytes==n && r.samples==3 && r.passes>=3 && r.seconds>=0.006);
            assert(isfinite(mb_result_value(&r)) && mb_result_value(&r)>0);
            assert(mb_result_minimum(&r)<=mb_result_value(&r) && mb_result_maximum(&r)>=mb_result_value(&r));
        }
    }
    /* Reuse the JIT mapping for a smaller code footprint as the UI does on reruns. */
    mb_status jit=mb_measure(ctx,MB_EXECUTE,4096,0.002,2,&r);
    assert(jit==MB_OK || jit==MB_UNAVAILABLE);
    const double values[]={5,1,4,2,3}; mb_statistics stats;
    assert(mb_summarize(values,5,&stats));
    assert(stats.median==3 && stats.minimum==1 && stats.maximum==5 && stats.mean==3);
    assert(fabs(stats.standard_deviation-sqrt(2))<1e-12);
    assert(fabs(stats.cv_percent-sqrt(2)/3*100)<1e-10);
    assert(mb_summarize(values,4,&stats) && stats.median==3);
    assert(mb_summarize(values,1,&stats) && stats.cv_percent==0);
    assert(!mb_summarize(values,0,&stats));
    assert(!mb_summarize(values,10,&stats));
    assert(!mb_summarize((double[]){1,NAN},2,&stats));
    assert(!mb_summarize((double[]){1,INFINITY},2,&stats));
    assert(!mb_summarize((double[]){1,0},2,&stats));
    for (unsigned samples=1;samples<=MB_MAX_SAMPLES;++samples) {
        assert(mb_measure(ctx,MB_LATENCY,4096+256,0.001,samples,&r)==MB_OK);
        assert(r.gb_per_second==0 && r.nanoseconds_per_load>0);
        assert(mb_summarize(r.sample_values,r.samples,&stats));
        assert(stats.median==mb_result_value(&r) && stats.cv_percent==r.cv_percent);
        assert(r.passes%1024==0);
    }
    volatile sig_atomic_t flag=1;
    mb_set_cancel_flag(ctx,&flag);
    assert(mb_measure(ctx,MB_LATENCY,4096,0.001,1,&r)==MB_CANCELLED);
    flag=0; mb_set_cancel_flag(ctx,NULL);
    pthread_t worker; assert(pthread_create(&worker,NULL,cancel_later,ctx)==0);
    assert(mb_measure(ctx,MB_READ,4096,0.2,9,&r)==MB_CANCELLED);
    pthread_join(worker,NULL);
    assert(mb_measure(ctx,MB_WRITE,4096,0.002,3,&r)==MB_CANCELLED);
    mb_destroy(ctx);
    ctx=mb_create(); assert(ctx);
    for (size_t block=32;block<=256;block*=2) for (int op=0;op<2;++op) {
        const size_t strides[]={block,1024,4096,11264};
        for (unsigned i=0;i<4;++i) {
            assert(mb_measure_blocks(ctx,(mb_operation)op,65536,block,strides[i],.001,3,&r)==MB_OK);
            verify_timing(r);
            assert(r.block_bytes==block && r.stride_bytes==strides[i] && r.samples==3 && r.passes>=3);
            assert(r.minimum_gb_per_second<=mb_result_mean(&r) && mb_result_mean(&r)<=r.maximum_gb_per_second);
            // Harmonic aggregate from elapsed times must lie between sample extrema.
            size_t useful=((r.bytes-block)/strides[i]+1)*block;
            double aggregate=(double)useful*r.passes/r.seconds/1e9;
            assert(aggregate>=r.minimum_gb_per_second*(1-1e-12) && aggregate<=r.maximum_gb_per_second*(1+1e-12));
        }
    }
    assert(mb_measure_blocks(ctx,MB_EXECUTE,65536,32,1024,.001,3,&r)==MB_ERROR);
    assert(mb_measure_blocks(ctx,MB_READ,65536,16,1024,.001,3,&r)==MB_ERROR);
    assert(mb_measure_blocks(ctx,MB_READ,65536,32,1025,.001,3,&r)==MB_ERROR);
    assert(mb_measure_blocks(ctx,MB_READ,65536,32,1024,NAN,3,&r)==MB_ERROR);
    assert(pthread_create(&worker,NULL,cancel_later,ctx)==0);
    assert(mb_measure_blocks(ctx,MB_WRITE,65536,128,4096,.2,9,&r)==MB_CANCELLED);
    pthread_join(worker,NULL); mb_destroy(ctx);
    puts("PASS: sweep, four workloads, raw samples, statistics, mapping reuse, cancellation");
    return 0;
}


