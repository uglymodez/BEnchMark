/* Inspect the actual private graph: a single cycle must cover every slot. */
#include "../Sources/benchmark.c"
#include <assert.h>
int main(void) {
    mb_context *ctx=mb_create(); assert(ctx);
    const size_t sizes[]={4096,4352,16384,1024*1024,4096};
    for (size_t k=0;k<sizeof(sizes)/sizeof(*sizes);++k) {
        size_t n=sizes[k], nodes=n/MB_LATENCY_STRIDE;
        assert(prepare_chain(ctx,n)==MB_OK);
        unsigned char *seen=calloc(nodes,1); assert(seen);
        uintptr_t cursor=(uintptr_t)ctx->data; uint64_t hash=0;
        for (size_t i=0;i<nodes;++i) {
            assert(cursor>=(uintptr_t)ctx->data && cursor<(uintptr_t)ctx->data+n);
            size_t offset=cursor-(uintptr_t)ctx->data;
            assert(offset%MB_LATENCY_STRIDE==0 && !seen[offset/MB_LATENCY_STRIDE]);
            seen[offset/MB_LATENCY_STRIDE]=1; hash=hash*131+offset;
            cursor=*(uintptr_t *)cursor;
        }
        assert(cursor==(uintptr_t)ctx->data);
        assert(prepare_chain(ctx,n)==MB_OK);
        cursor=(uintptr_t)ctx->data; uint64_t repeated=0;
        for (size_t i=0;i<nodes;++i) { repeated=repeated*131+cursor-(uintptr_t)ctx->data; cursor=*(uintptr_t *)cursor; }
        assert(hash==repeated);
        free(seen);
    }
    mb_cancel(ctx); assert(prepare_chain(ctx,1024*1024)==MB_CANCELLED);
    mb_destroy(ctx); puts("PASS: pointer chain covers every slot once, closes, repeats and cancels");
}
