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
    const volatile sig_atomic_t *cancel_flag;
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
    return ctx && (atomic_load_explicit(&ctx->cancelled, memory_order_relaxed) ||
                   (ctx->cancel_flag && *ctx->cancel_flag));
}
void mb_set_cancel_flag(mb_context *ctx, const volatile sig_atomic_t *flag) {
    if (ctx) ctx->cancel_flag = flag;
}
const char *mb_error(const mb_context *ctx) { return ctx ? ctx->error : "No context"; }
const char *mb_architecture(void) {
#if defined(__aarch64__)
    return "arm64 / NEON 128-bit";
#else
    return "x86_64 / SSE2 128-bit";
#endif
}
const char *mb_method_version(void) { return "MBM-2.0"; }

double mb_result_mean(const mb_result *r) {
    mb_statistics stats;
    return r && mb_summarize(r->sample_values,r->samples,&stats) ? stats.mean : 0;
}

size_t mb_profile_sizes(size_t maximum, size_t *sizes, size_t capacity) {
    if (!sizes || maximum<64UL*1024*1024 || maximum>1024UL*1024*1024 || maximum%256) return 0;
    size_t count=0;
    for (size_t base=4096;base<maximum;base*=2) {
        for (size_t step=0;step<16;++step) {
            size_t bytes=base+base/16*step;
            if (bytes>=maximum) break;
            if (count>=capacity) return 0;
            sizes[count++]=bytes;
        }
    }
    if (count>=capacity) return 0;
    sizes[count++]=maximum;
    return count;
}
size_t mb_compact_sizes(size_t maximum, size_t *sizes, size_t capacity) {
    if (!sizes || capacity<5 || maximum<64UL*1024*1024 ||
        maximum>1024UL*1024*1024 || maximum%256) return 0;
    const size_t fixed[]={4096,64*1024,1024*1024,16*1024*1024};
    memcpy(sizes,fixed,sizeof(fixed)); sizes[4]=maximum;
    return 5;
}

const char *mb_operation_name(mb_operation op) {
    switch (op) {
        case MB_READ: return "read";
        case MB_WRITE: return "write";
        case MB_EXECUTE: return "execute_proxy";
        case MB_LATENCY: return "latency";
    }
    return "unknown";
}
const char *mb_operation_unit(mb_operation op) { return op == MB_LATENCY ? "ns/load" : "GB/s"; }
double mb_result_value(const mb_result *r) {
    return r->operation == MB_LATENCY ? r->nanoseconds_per_load : r->gb_per_second;
}
double mb_result_minimum(const mb_result *r) {
    return r->operation == MB_LATENCY ? r->minimum_nanoseconds_per_load : r->minimum_gb_per_second;
}
double mb_result_maximum(const mb_result *r) {
    return r->operation == MB_LATENCY ? r->maximum_nanoseconds_per_load : r->maximum_gb_per_second;
}
int mb_summarize(const double *values, unsigned count, mb_statistics *out) {
    if (!out) return 0;
    memset(out, 0, sizeof(*out));
    if (!values || !count || count > MB_MAX_SAMPLES) return 0;
    double sorted[MB_MAX_SAMPLES], mean = 0, m2 = 0;
    for (unsigned i = 0; i < count; ++i) {
        if (!isfinite(values[i]) || values[i] <= 0) return 0;
        sorted[i] = values[i];
        double delta = values[i] - mean;
        mean += delta / (i + 1);
        m2 += delta * (values[i] - mean);
    }
    for (unsigned i = 1; i < count; ++i) {
        double v = sorted[i]; unsigned j = i;
        while (j && sorted[j - 1] > v) { sorted[j] = sorted[j - 1]; --j; }
        sorted[j] = v;
    }
    out->median = count % 2 ? sorted[count/2] : (sorted[count/2-1] + sorted[count/2])/2;
    out->minimum = sorted[0]; out->maximum = sorted[count-1]; out->mean = mean;
    out->standard_deviation = sqrt(fmax(0, m2 / count));
    out->cv_percent = out->standard_deviation / mean * 100;
    if (!isfinite(out->median) || !isfinite(out->cv_percent)) {
        memset(out, 0, sizeof(*out)); return 0;
    }
    return 1;
}

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

/* Insert each new node after a uniformly selected existing node. This creates
   one deterministic shuffled cycle covering every 128-byte slot, with no second
   allocation. 128 is the workload spacing, not a detected cache-line size. */
static mb_status prepare_chain(mb_context *ctx, size_t n) {
    mb_status status = prepare_data(ctx, n);
    if (status != MB_OK) return status;
    uint64_t state = UINT64_C(0xd1b54a32d192ed03);
    *(uintptr_t *)ctx->data = (uintptr_t)ctx->data;
    size_t nodes = n / MB_LATENCY_STRIDE;
    for (size_t i = 1; i < nodes; ++i) {
        uint64_t random, bound = (uint64_t)i, threshold = (uint64_t)(-bound) % bound;
        do {
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27;
            random = state * UINT64_C(2685821657736338717);
        } while (random < threshold);
        uintptr_t *previous = (uintptr_t *)(ctx->data + (random % bound) * MB_LATENCY_STRIDE);
        uintptr_t *node = (uintptr_t *)(ctx->data + i * MB_LATENCY_STRIDE);
        *node = *previous; *previous = (uintptr_t)node;
        if ((i & 4095) == 0 && mb_is_cancelled(ctx)) return MB_CANCELLED;
    }
    return MB_OK;
}
static NOINLINE uintptr_t chase(uintptr_t cursor, size_t loads) {
    /* Each address depends on the preceding load. Volatile preserves every
       access; no independent streams can hide memory latency. */
    for (size_t i = 0; i < loads; ++i) cursor = *(const volatile uintptr_t *)cursor;
    return cursor;
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
    if (op < MB_READ || op > MB_LATENCY || n < MB_MIN || n > MB_MAX || n % 256 ||
        !isfinite(duration) || duration < 0.001 || duration > 1.0 || count < 1 || count > MB_MAX_SAMPLES) {
        problem(ctx, "Invalid benchmark settings."); return MB_ERROR;
    }
    if (mb_is_cancelled(ctx)) return MB_CANCELLED;
    if (op == MB_EXECUTE && n > MB_CODE_MAX) {
        problem(ctx, "Instruction test is limited to 64 MiB."); return MB_UNAVAILABLE;
    }
    mb_status status = op == MB_EXECUTE ? prepare_code(ctx,n) :
                       op == MB_LATENCY ? prepare_chain(ctx,n) : prepare_data(ctx,n);
    if (status != MB_OK) return status;
    uintptr_t cursor = (uintptr_t)ctx->data;
    if (op == MB_LATENCY) {
        size_t remaining = n / MB_LATENCY_STRIDE;
        while (remaining) {
            size_t loads = remaining < 1024 ? remaining : 1024;
            cursor = chase(cursor, loads); remaining -= loads;
            if (mb_is_cancelled(ctx)) return MB_CANCELLED;
        }
    } else one_pass(ctx,op,n); /* Untimed warmup. */
    if (op == MB_WRITE) finish_stores();
    double rates[MB_MAX_SAMPLES]; double elapsed_total = 0; uint64_t total = 0;
    /* Batches cap timer overhead for tiny buffers. At most 1 MiB per check;
       large working sets check cancellation between individual passes. */
    size_t batch = (1024*1024)/n;
    if (batch < 1) batch = 1;
    for (unsigned s=0; s<count; ++s) {
        if (mb_is_cancelled(ctx)) return MB_CANCELLED;
        uint64_t passes = 0; double start = now(), elapsed;
        do {
            if (op == MB_LATENCY) { cursor = chase(cursor, 1024); passes += 1024; }
            else { for (size_t k=0; k<batch; ++k) one_pass(ctx,op,n); passes += batch; }
            if (op == MB_WRITE) finish_stores();
            elapsed = now()-start;
            if (mb_is_cancelled(ctx)) return MB_CANCELLED;
        } while (elapsed < duration);
        if (elapsed <= 0 || !isfinite(elapsed)) {
            problem(ctx, "Invalid clock measurement."); return MB_ERROR;
        }
        rates[s] = op == MB_LATENCY ? elapsed * 1e9 / (double)passes :
                   ((double)n * (double)passes) / elapsed / 1e9;
        elapsed_total += elapsed; total += passes;
    }
    ctx->sink ^= cursor;
    mb_statistics stats;
    if (!mb_summarize(rates, count, &stats)) {
        problem(ctx, "Invalid sample statistics."); return MB_ERROR;
    }
    out->bytes=n; out->operation=op; out->seconds=elapsed_total;
    out->passes=total; out->samples=count; out->cv_percent=stats.cv_percent;
    memcpy(out->sample_values, rates, count * sizeof(double));
    if (op == MB_LATENCY) {
        out->nanoseconds_per_load=stats.median;
        out->minimum_nanoseconds_per_load=stats.minimum;
        out->maximum_nanoseconds_per_load=stats.maximum;
    } else {
        out->gb_per_second=stats.median;
        out->minimum_gb_per_second=stats.minimum;
        out->maximum_gb_per_second=stats.maximum;
    }
    return MB_OK;
}


/* All offsets are 16-byte aligned. Explicit SIMD accesses preserve the work;
   holes between blocks are not included in throughput. */
static NOINLINE uint64_t block_pass(unsigned char *p, size_t n, size_t block, size_t stride, int write) {
    uint64_t sink=0;
#if defined(__aarch64__)
    uint64x2_t acc=vdupq_n_u64(0), value=vdupq_n_u64(UINT64_C(0x9e3779b97f4a7c15));
#else
    __m128i acc=_mm_setzero_si128(), value=_mm_set1_epi64x((long long)UINT64_C(0x9e3779b97f4a7c15));
#endif
    for (size_t i=0;i<=n-block;i+=stride) for (size_t j=0;j<block;j+=16) {
#if defined(__aarch64__)
        if (write) __asm__ volatile("str %q0, [%1]" :: "w"(value), "r"(p+i+j) : "memory");
        else { uint64x2_t v; __asm__ volatile("ldr %q0, [%1]" : "=w"(v) : "r"(p+i+j) : "memory"); acc=veorq_u64(acc,v); }
#else
        if (write) __asm__ volatile("movdqa %0, (%1)" :: "x"(value), "r"(p+i+j) : "memory");
        else { __m128i v; __asm__ volatile("movdqa (%1), %0" : "=x"(v) : "r"(p+i+j) : "memory"); acc=_mm_xor_si128(acc,v); }
#endif
    }
#if defined(__aarch64__)
    sink=vgetq_lane_u64(acc,0)^vgetq_lane_u64(acc,1);
#else
    sink=(uint64_t)_mm_cvtsi128_si64(acc)^(uint64_t)_mm_cvtsi128_si64(_mm_srli_si128(acc,8));
#endif
    return sink;
}
mb_status mb_measure_blocks(mb_context *ctx, mb_operation op, size_t n,
    size_t block, size_t stride, double duration, unsigned count, mb_result *out) {
    if (!ctx || !out) return MB_ERROR;
    memset(out,0,sizeof(*out)); ctx->error[0]=0;
    if ((op!=MB_READ && op!=MB_WRITE) || n<16384 || n>MB_MAX || n%256 ||
        (block!=32 && block!=64 && block!=128 && block!=256) ||
        (stride!=block && (stride<1024 || stride>11264 || stride%256)) ||
        !isfinite(duration) || duration<.001 || duration>1 || count<1 || count>MB_MAX_SAMPLES) {
        problem(ctx,"Invalid block workload settings."); return MB_ERROR;
    }
    if (mb_is_cancelled(ctx)) return MB_CANCELLED;
    mb_status status=prepare_data(ctx,n); if (status!=MB_OK) return status;
    ctx->sink^=block_pass(ctx->data,n,block,stride,op==MB_WRITE);
    if (op==MB_WRITE) finish_stores();
    size_t useful=((n-block)/stride+1)*block;
    double values[MB_MAX_SAMPLES],seconds=0; uint64_t total=0;
    for (unsigned s=0;s<count;++s) {
        double start=now(),elapsed; uint64_t passes=0;
        do {
            if (mb_is_cancelled(ctx)) return MB_CANCELLED;
            ctx->sink^=block_pass(ctx->data,n,block,stride,op==MB_WRITE); ++passes;
            if (op==MB_WRITE) finish_stores();
            elapsed=now()-start;
        } while (elapsed<duration);
        values[s]=(double)useful*passes/elapsed/1e9; seconds+=elapsed; total+=passes;
    }
    if (mb_is_cancelled(ctx)) return MB_CANCELLED;
    mb_statistics stats;
    if (!mb_summarize(values,count,&stats)) { problem(ctx,"Invalid block statistics."); return MB_ERROR; }
    out->bytes=n; out->block_bytes=block; out->stride_bytes=stride; out->operation=op;
    out->samples=count; out->seconds=seconds; out->passes=total;
    out->gb_per_second=stats.median; out->minimum_gb_per_second=stats.minimum;
    out->maximum_gb_per_second=stats.maximum; out->cv_percent=stats.cv_percent;
    memcpy(out->sample_values,values,count*sizeof(double)); return MB_OK;
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


