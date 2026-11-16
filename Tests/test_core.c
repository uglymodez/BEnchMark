#define _POSIX_C_SOURCE 200809L
#include "benchmark.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <time.h>

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
    mb_context *ctx=mb_create(); assert(ctx);
    mb_result r;
    assert(mb_measure(ctx,MB_READ,4097,0.002,3,&r)==MB_ERROR);
    assert(mb_measure(ctx,MB_READ,4096,NAN,3,&r)==MB_ERROR);
    assert(mb_measure(ctx,MB_READ,4096,0.002,0,&r)==MB_ERROR);
    assert(mb_measure(ctx,MB_EXECUTE,128*1024*1024,0.002,3,&r)==MB_UNAVAILABLE);
    for (int op=MB_READ; op<=MB_EXECUTE; ++op) {
        for (size_t n=4096; n<=1024*1024; n*=16) {
            mb_status status=mb_measure(ctx,(mb_operation)op,n,0.002,3,&r);
            if (op==MB_EXECUTE && status==MB_UNAVAILABLE) {
                fprintf(stderr,"SKIP execute: %s\n",mb_error(ctx)); break;
            }
            assert(status==MB_OK);
            assert(r.bytes==n && r.samples==3 && r.passes>=3 && r.seconds>=0.006);
            assert(isfinite(r.gb_per_second) && r.gb_per_second>0);
            assert(r.minimum_gb_per_second<=r.gb_per_second && r.maximum_gb_per_second>=r.gb_per_second);
        }
    }
    /* Reuse the JIT mapping for a smaller code footprint as the UI does on reruns. */
    mb_status jit=mb_measure(ctx,MB_EXECUTE,4096,0.002,2,&r);
    assert(jit==MB_OK || jit==MB_UNAVAILABLE);
    pthread_t worker; assert(pthread_create(&worker,NULL,cancel_later,ctx)==0);
    assert(mb_measure(ctx,MB_READ,4096,0.2,9,&r)==MB_CANCELLED);
    pthread_join(worker,NULL);
    assert(mb_measure(ctx,MB_WRITE,4096,0.002,3,&r)==MB_CANCELLED);
    mb_destroy(ctx);
    puts("PASS: sweep, validation, read/write/execute, statistics, mapping reuse, cancellation");
    return 0;
}
