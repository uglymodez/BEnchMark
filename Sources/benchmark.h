#ifndef MB_BENCHMARK_H
#define MB_BENCHMARK_H
#include <stddef.h>
#include <stdint.h>

/* Single worker per context. Only mb_cancel may be called concurrently. */
typedef struct mb_context mb_context;
typedef enum { MB_READ = 0, MB_WRITE = 1, MB_EXECUTE = 2 } mb_operation;
typedef enum { MB_OK = 0, MB_CANCELLED = 1, MB_UNAVAILABLE = 2, MB_ERROR = 3 } mb_status;
typedef struct {
    size_t bytes;
    mb_operation operation;
    double gb_per_second; /* Decimal GB/s; instruction footprint/s for EXECUTE. */
    double minimum_gb_per_second;
    double maximum_gb_per_second;
    double seconds;       /* Sum of completed timed samples, excludes warmup. */
    uint64_t passes;
    unsigned samples;
} mb_result;

mb_context *mb_create(void);
void mb_destroy(mb_context *ctx); /* Worker must have finished. */
void mb_cancel(mb_context *ctx);
int mb_is_cancelled(const mb_context *ctx);
const char *mb_error(const mb_context *ctx);
const char *mb_architecture(void);
const char *mb_method_version(void);
/* Sizes: 4 KiB .. 1 GiB, multiples of 256. Execute: up to 64 MiB. */
mb_status mb_measure(mb_context *ctx, mb_operation operation, size_t bytes,
                     double sample_seconds, unsigned samples, mb_result *result);
/* Quarter-octave sizes; returns count, or 0 for invalid/insufficient capacity. */
size_t mb_sizes(size_t maximum, size_t *sizes, size_t capacity);
#endif
