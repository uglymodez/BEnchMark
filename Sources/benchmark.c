#define _GNU_SOURCE
#include "benchmark.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <errno.h>
#include <time.h>
#include <sys/mman.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <pthread.h>
#include <libkern/OSCacheControl.h>
#endif
#if defined(__aarch64__)
#include <arm_neon.h>
#elif defined(__x86_64__)
#include <emmintrin.h>
#else
#error This benchmark supports arm64 and x86_64 only.
#endif

#define MB_MIN ((size_t)4096)
#define MB_MAX ((size_t)1024 * 1024 * 1024)
#define MB_CODE_MAX ((size_t)64 * 1024 * 1024)
#define NOINLINE __attribute__((noinline))
struct mb_context {
    atomic_bool cancelled;
    unsigned char *data;
    size_t data_size;
    void *code;
    size_t code_capacity;
    volatile uint64_t sink;
    char error[256];
};

static double now(void) {
    struct timespec t;
#ifdef CLOCK_MONOTONIC_RAW
    clock_gettime(CLOCK_MONOTONIC_RAW, &t);
#else
    clock_gettime(CLOCK_MONOTONIC, &t);
#endif
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}
static void problem(mb_context *ctx, const char *message) {
    snprintf(ctx->error, sizeof(ctx->error), "%s", message);
}
mb_context *mb_create(void) {
    mb_context *ctx = calloc(1, sizeof(*ctx));
    if (ctx) atomic_init(&ctx->cancelled, 0);
    return ctx;
}
void mb_destroy(mb_context *ctx) {
    if (!ctx) return;
    free(ctx->data);
    if (ctx->code) munmap(ctx->code, ctx->code_capacity);
    free(ctx);
}
void mb_cancel(mb_context *ctx) {
    if (ctx) atomic_store_explicit(&ctx->cancelled, 1, memory_order_relaxed);
}
int mb_is_cancelled(const mb_context *ctx) {
    return ctx && atomic_load_explicit(&ctx->cancelled, memory_order_relaxed);
}
const char *mb_error(const mb_context *ctx) { return ctx ? ctx->error : "No context"; }
const char *mb_architecture(void) {
#if defined(__aarch64__)
    return "arm64 / NEON 128-bit";
#else
    return "x86_64 / SSE2 128-bit";
#endif
}
const char *mb_method_version(void) { return "MBM-1.0"; }

/* Explicit 128-bit loads/stores: no optimizer may remove/rewrite the memory
   traffic. Four independent accumulators hide XOR dependency latency. Compiler
   barriers are inside the loop; their empty assembly emits no instructions. */
static NOINLINE uint64_t read_pass(const unsigned char *p, size_t n) {
#if defined(__aarch64__)
    uint64x2_t a = vdupq_n_u64(0), b = a, c = a, d = a;
    for (size_t i = 0; i < n; i += 64) {
        uint64x2_t x0, x1, x2, x3;
        __asm__ volatile("ldp %q0, %q1, [%4]\n\tldp %q2, %q3, [%4, #32]"
            : "=&w"(x0), "=&w"(x1), "=&w"(x2), "=&w"(x3) : "r"(p+i) : "memory");
        a = veorq_u64(a, x0); b = veorq_u64(b, x1);
        c = veorq_u64(c, x2); d = veorq_u64(d, x3);
    }
    a = veorq_u64(veorq_u64(a,b), veorq_u64(c,d));
    return vgetq_lane_u64(a,0) ^ vgetq_lane_u64(a,1);
#else
    __m128i a = _mm_setzero_si128(), b = a, c = a, d = a;
    for (size_t i = 0; i < n; i += 64) {
        __m128i x0, x1, x2, x3;
        __asm__ volatile("movdqa 0(%4), %0\n\tmovdqa 16(%4), %1\n\t"
                         "movdqa 32(%4), %2\n\tmovdqa 48(%4), %3"
            : "=&x"(x0), "=&x"(x1), "=&x"(x2), "=&x"(x3) : "r"(p+i) : "memory");
        a = _mm_xor_si128(a,x0); b = _mm_xor_si128(b,x1);
        c = _mm_xor_si128(c,x2); d = _mm_xor_si128(d,x3);
    }
    a = _mm_xor_si128(_mm_xor_si128(a,b),_mm_xor_si128(c,d));
    return (uint64_t)_mm_cvtsi128_si64(a) ^ (uint64_t)_mm_cvtsi128_si64(_mm_srli_si128(a,8));
#endif
}
static NOINLINE void write_pass(unsigned char *p, size_t n) {
#if defined(__aarch64__)
    uint64x2_t v = vdupq_n_u64(UINT64_C(0x9e3779b97f4a7c15));
    for (size_t i = 0; i < n; i += 64)
        __asm__ volatile("stp %q0, %q0, [%1]\n\tstp %q0, %q0, [%1, #32]"
                         :: "w"(v), "r"(p+i) : "memory");
#else
    __m128i v = _mm_set1_epi64x((long long)UINT64_C(0x9e3779b97f4a7c15));
    for (size_t i = 0; i < n; i += 64)
        __asm__ volatile("movdqa %0, 0(%1)\n\tmovdqa %0, 16(%1)\n\t"
                         "movdqa %0, 32(%1)\n\tmovdqa %0, 48(%1)"
                         :: "x"(v), "r"(p+i) : "memory");
#endif
}
static void finish_stores(void) {
#if defined(__aarch64__)
    __asm__ volatile("dsb ish" ::: "memory");
#else
    _mm_mfence();
#endif
}

static mb_status prepare_data(mb_context *ctx, size_t n) {
    if (ctx->data_size >= n) return MB_OK;
    free(ctx->data); ctx->data = NULL; ctx->data_size = 0;
    void *p = NULL;
    if (posix_memalign(&p, 16384, n) != 0) {
        problem(ctx, "Not enough memory to allocate the data buffer."); return MB_ERROR;
    }
    ctx->data = p; ctx->data_size = n;
    /* Prefault pages with nonuniform data, outside all timed regions. */
    uint64_t x = UINT64_C(0x123456789abcdef);
    uint64_t *words = p;
    for (size_t i = 0; i < n/8; ++i) {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17; words[i] = x;
        if ((i & 131071) == 0 && mb_is_cancelled(ctx)) return MB_CANCELLED;
    }
    return MB_OK;
}

static mb_status prepare_code(mb_context *ctx, size_t n) {
    if (!ctx->code) {
        int flags = MAP_PRIVATE | MAP_ANONYMOUS;
        int protection = PROT_READ | PROT_WRITE;
#if defined(__APPLE__)
        flags |= MAP_JIT;
        protection |= PROT_EXEC;
#endif
        void *p = mmap(NULL, MB_CODE_MAX, protection, flags, -1, 0);
        if (p == MAP_FAILED) {
            snprintf(ctx->error, sizeof(ctx->error), "Executable buffer unavailable: %s", strerror(errno));
            return MB_UNAVAILABLE;
        }
        ctx->code = p; ctx->code_capacity = MB_CODE_MAX;
    }
#if defined(__APPLE__) && defined(__aarch64__)
    pthread_jit_write_protect_np(0);
#elif !defined(__APPLE__)
    if (mprotect(ctx->code, ctx->code_capacity, PROT_READ | PROT_WRITE) != 0) {
        problem(ctx, "Cannot make instruction buffer writable."); return MB_UNAVAILABLE;
    }
#endif
    /* Fixed, local NOP + RET code only. No files, downloads or user code. This
       is a sequential instruction-footprint test, NOT direct I-cache bandwidth. */
#if defined(__aarch64__)
    uint32_t *code = ctx->code;
    for (size_t i=0; i<n/4; ++i) code[i] = UINT32_C(0xd503201f); /* NOP */
    code[n/4-1] = UINT32_C(0xd65f03c0); /* RET x30 */
#else
    memset(ctx->code, 0x90, n);
    ((unsigned char *)ctx->code)[n-1] = 0xc3; /* RET */
#endif
#if defined(__APPLE__) && defined(__aarch64__)
    pthread_jit_write_protect_np(1);
#elif !defined(__APPLE__)
    if (mprotect(ctx->code, ctx->code_capacity, PROT_READ | PROT_EXEC) != 0) {
        problem(ctx, "Cannot make instruction buffer executable."); return MB_UNAVAILABLE;
    }
#endif
#if defined(__APPLE__)
    sys_icache_invalidate(ctx->code, n);
#else
    __builtin___clear_cache(ctx->code, (char *)ctx->code + n);
#endif
    return mb_is_cancelled(ctx) ? MB_CANCELLED : MB_OK;
}

static void one_pass(mb_context *ctx, mb_operation op, size_t n) {
    if (op == MB_READ) ctx->sink ^= read_pass(ctx->data, n);
    else if (op == MB_WRITE) write_pass(ctx->data, n);
    else ((void (*)(void))ctx->code)();
}

mb_status mb_measure(mb_context *ctx, mb_operation op, size_t n,
                     double duration, unsigned count, mb_result *out) {
    if (!ctx || !out) return MB_ERROR;
    memset(out, 0, sizeof(*out)); ctx->error[0] = '\0';
    if (op < MB_READ || op > MB_EXECUTE || n < MB_MIN || n > MB_MAX || n % 256 ||
        !isfinite(duration) || duration < 0.001 || duration > 1.0 || count < 1 || count > 9) {
        problem(ctx, "Invalid benchmark settings."); return MB_ERROR;
    }
    if (mb_is_cancelled(ctx)) return MB_CANCELLED;
    if (op == MB_EXECUTE && n > MB_CODE_MAX) {
        problem(ctx, "Instruction test is limited to 64 MiB."); return MB_UNAVAILABLE;
    }
    mb_status status = op == MB_EXECUTE ? prepare_code(ctx,n) : prepare_data(ctx,n);
    if (status != MB_OK) return status;
    one_pass(ctx,op,n); /* Untimed warmup. */
    if (op == MB_WRITE) finish_stores();
    double rates[9]; double elapsed_total = 0; uint64_t total = 0;
    /* Batches cap timer overhead for tiny buffers. At most 1 MiB per check;
       large working sets check cancellation between individual passes. */
    size_t batch = (1024*1024)/n;
    if (batch < 1) batch = 1;
    for (unsigned s=0; s<count; ++s) {
        if (mb_is_cancelled(ctx)) return MB_CANCELLED;
        uint64_t passes = 0; double start = now(), elapsed;
        do {
            for (size_t k=0; k<batch; ++k) one_pass(ctx,op,n);
            passes += batch;
            if (op == MB_WRITE) finish_stores();
            elapsed = now()-start;
            if (mb_is_cancelled(ctx)) return MB_CANCELLED;
        } while (elapsed < duration);
        if (elapsed <= 0 || !isfinite(elapsed)) {
            problem(ctx, "Invalid clock measurement."); return MB_ERROR;
        }
        rates[s] = ((double)n * (double)passes) / elapsed / 1e9;
        elapsed_total += elapsed; total += passes;
    }
    for (unsigned i=1; i<count; ++i) {
        double value = rates[i]; unsigned j=i;
        while (j>0 && rates[j-1]>value) { rates[j]=rates[j-1]; --j; }
        rates[j]=value;
    }
    out->bytes=n; out->operation=op; out->seconds=elapsed_total;
    out->passes=total; out->samples=count;
    out->gb_per_second = count%2 ? rates[count/2] : (rates[count/2-1]+rates[count/2])/2;
    out->minimum_gb_per_second=rates[0]; out->maximum_gb_per_second=rates[count-1];
    return MB_OK;
}

size_t mb_sizes(size_t max, size_t *sizes, size_t capacity) {
    if (max<MB_MIN || max>MB_MAX || max%256 || !sizes) return 0;
    size_t values[80], count=0, previous=0;
    for (unsigned step=0; step<80; ++step) {
        size_t n = (size_t)(4096.0 * exp2((double)step/4.0) / 256.0 + 0.5) * 256;
        if (n>=max) break;
        if (n != previous) { values[count++]=n; previous=n; }
    }
    values[count++]=max;
    if (capacity<count) return 0;
    memcpy(sizes,values,count*sizeof(size_t)); return count;
}
