/* Inspect actual address coverage, including untouched gaps and buffer edges. */
#include "../Sources/benchmark.c"
#include <assert.h>
#include <pthread.h>
static void *cancel_blocks(void *arg) {
    struct timespec delay={0,10000000}; nanosleep(&delay,NULL); mb_cancel(arg); return NULL;
}
int main(void) {
    int gaps[MB_GAP_CAPACITY];
    assert(mb_access_gaps(gaps,MB_GAP_CAPACITY)==47);
    assert(!mb_access_gaps(gaps,46) && !mb_access_gaps(NULL,47));
    assert(gaps[0]==-3072 && gaps[46]==7168);
    for (unsigned i=1;i<47;++i) assert(gaps[i]>gaps[i-1]);
    mb_context *ctx=mb_create(); assert(ctx);
    for (size_t bytes=4096;bytes<=16384;bytes*=2) {
        assert(prepare_data(ctx,bytes)==MB_OK);
        unsigned char *expected=calloc(1,bytes); assert(expected);
        for (unsigned block=32;block<=256;block*=2) for (unsigned g=0;g<47;++g) {
            memset(ctx->data,0,bytes); memset(expected,0,bytes);
            size_t step=block+(size_t)abs(gaps[g]),visits=mb_block_visits(bytes,block,gaps[g]);
            assert(visits && (visits-1)*step+block<=bytes);
            assert(visits*step+block>bytes);
            uint64_t value=UINT64_C(0x9e3779b97f4a7c15);
            for (size_t i=0;i<visits;++i) for (unsigned j=0;j<block;j+=8) memcpy(expected+i*step+j,&value,8);
            block_pass(ctx,MB_WRITE,bytes,block,gaps[g]); finish_stores();
            assert(memcmp(ctx->data,expected,bytes)==0);
            // Use non-uniform data; verify read reduction, not only absence of a crash.
            uint64_t sum=0;
            for (size_t i=0;i<bytes/8;++i) ((uint64_t *)ctx->data)[i]=i*UINT64_C(0x123456789)+3;
            for (size_t i=0;i<visits;++i) for (unsigned j=0;j<block;j+=8) sum^=*(uint64_t *)(ctx->data+i*step+j);
            ctx->sink=0; block_pass(ctx,MB_READ,bytes,block,gaps[g]); assert(ctx->sink==sum);
        }
        free(expected);
    }
    mb_result r;
    for (unsigned block=32;block<=256;block*=2) for (int op=MB_READ;op<=MB_WRITE;++op) {
        for (int gap=-256;gap<=256;gap+=256) {
            assert(mb_measure_blocks(ctx,(mb_operation)op,65536,block,gap,0.001,3,&r)==MB_OK);
            assert(r.block_bytes==block && r.access_gap_bytes==gap && r.samples==3);
            double traffic=mb_block_visits(r.bytes,block,gap)*block;
            // Identical time-budgeted samples: aggregate byte rate must lie in sample range.
            double rate=traffic*r.passes/r.seconds/1e9;
            assert(rate>=r.minimum_gb_per_second*(1-1e-10) && rate<=r.maximum_gb_per_second*(1+1e-10));
        }
    }
    assert(!mb_block_visits(4096,16,0)); assert(!mb_block_visits(4096,32,INT32_MIN));
    assert(!mb_block_visits(4096,32,1)); assert(!mb_block_visits(4097,32,0));
    assert(mb_measure_blocks(ctx,MB_EXECUTE,4096,32,0,0.001,1,&r)==MB_ERROR);
    assert(mb_measure_blocks(ctx,MB_READ,4096,32,0,NAN,1,&r)==MB_ERROR);
    pthread_t thread; assert(pthread_create(&thread,NULL,cancel_blocks,ctx)==0);
    assert(mb_measure_blocks(ctx,MB_WRITE,1024*1024,256,-3072,1,9,&r)==MB_CANCELLED);
    pthread_join(thread,NULL);
    assert(mb_measure_blocks(ctx,MB_READ,4096,32,0,0.001,1,&r)==MB_CANCELLED);
    mb_destroy(ctx);
    puts("PASS: all block/gap addresses, exact traffic accounting, read/write, reverse, cancellation");
}
