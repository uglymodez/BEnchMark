#ifndef MB_BENCHMARK_H
#define MB_BENCHMARK_H
#include <stddef.h>
#include <stdint.h>
#include <signal.h>

/* Single worker per context. Only mb_cancel may be called concurrently. */
typedef struct mb_context mb_context;
typedef enum { MB_READ = 0, MB_WRITE = 1, MB_EXECUTE = 2, MB_LATENCY = 3 } mb_operation;
typedef enum { MB_OK = 0, MB_CANCELLED = 1, MB_UNAVAILABLE = 2, MB_ERROR = 3 } mb_status;
#define MB_MAX_SAMPLES 9
#define MB_LATENCY_STRIDE 128
typedef struct {
    double median, minimum, maximum, mean, standard_deviation, cv_percent;
} mb_statistics;
typedef struct {
    size_t bytes;
    size_t block_bytes, stride_bytes; /* Zero for legacy workloads. */
    mb_operation operation;
    double gb_per_second; /* Decimal GB/s; instruction footprint/s for EXECUTE. */
    double minimum_gb_per_second;
    double maximum_gb_per_second;
    double seconds;       /* Sum of completed timed samples, excludes warmup. */
    uint64_t passes;
    unsigned samples;
    double nanoseconds_per_load; /* LATENCY only; GB/s fields remain zero. */
    double minimum_nanoseconds_per_load;
    double maximum_nanoseconds_per_load;
    double sample_values[MB_MAX_SAMPLES]; /* Chronological, in mb_operation_unit(). */
    double sample_seconds[MB_MAX_SAMPLES];
    uint64_t sample_iterations[MB_MAX_SAMPLES];
    uint64_t work_units_per_iteration; /* bytes; loads for MB_LATENCY */
    double warmup_target_seconds, warmup_seconds; /* Separate from measured samples. */
    uint64_t warmup_iterations;
    double cv_percent; /* Population standard deviation / mean, percent. */
} mb_result;

mb_context *mb_create(void);
void mb_destroy(mb_context *ctx); /* Worker must have finished. */
void mb_cancel(mb_context *ctx);
/* Set before measuring; flag must outlive the context. Signal handler sets it. */
void mb_set_cancel_flag(mb_context *ctx, const volatile sig_atomic_t *flag);
int mb_is_cancelled(const mb_context *ctx);
const char *mb_error(const mb_context *ctx);
const char *mb_architecture(void);
const char *mb_method_version(void);
const char *mb_operation_name(mb_operation operation);
const char *mb_operation_unit(mb_operation operation);
double mb_result_value(const mb_result *result);
double mb_result_minimum(const mb_result *result);
double mb_result_maximum(const mb_result *result);
double mb_result_mean(const mb_result *result);
/* Bounded time-based warmup for the same workload: 100..300 ms. */
double mb_warmup_duration(double sample_seconds);
/* Mean of last floor(n/2) vs first floor(n/2), excluding the middle sample.
   Signed change in the measured unit; zero if fewer than three samples. */
double mb_result_drift_percent(const mb_result *result);
/* Rejects nonfinite/nonpositive values; does not mutate input. */
int mb_summarize(const double *values, unsigned count, mb_statistics *statistics);
/* Sizes: 4 KiB .. 1 GiB, multiples of 256. Execute: up to 64 MiB. */
mb_status mb_measure(mb_context *ctx, mb_operation operation, size_t bytes,
                     double sample_seconds, unsigned samples, mb_result *result);
/* Block stride workload: 32/64/128/256 byte blocks, contiguous baseline or
   strides 1024..11264 in 256-byte steps. Counts only useful accessed bytes. */
#define MB_BLOCK_STEPS 41
mb_status mb_measure_blocks(mb_context *ctx, mb_operation op, size_t bytes,
    size_t block, size_t stride, double seconds, unsigned samples, mb_result *out);
/* Quarter-octave sizes; returns count, or 0 for invalid/insufficient capacity. */
size_t mb_sizes(size_t maximum, size_t *sizes, size_t capacity);
/* Five representative buffers, not detected hardware cache levels.
   4 KiB, 64 KiB, 1 MiB, 16 MiB, maximum (64 MiB .. 1 GiB). */
size_t mb_compact_sizes(size_t maximum, size_t *sizes, size_t capacity);
/* Detailed read/write chart: 16 intervals per doubling, including the five
   summary anchors. At most 289 sizes for a 1 GiB maximum. */
#define MB_PROFILE_CAPACITY 300
size_t mb_profile_sizes(size_t maximum, size_t *sizes, size_t capacity);
#endif


