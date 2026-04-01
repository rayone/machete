/*
 * cpu_compute.c - CPU Compute Throughput Benchmark
 *
 * Build: cc -O2 -pthread -o cpu_compute cpu_compute.c -lm
 * Usage: ./cpu_compute [num_threads]
 *
 * === METHODOLOGY ===
 *
 * SCALAR FMA (existing)
 *   8 independent accumulators per thread. At -O2, clang fuses a*m+m into
 *   a single FMADD instruction. Measures one FP32/FP64/INT64 op per lane
 *   per cycle, i.e. scalar pipeline throughput.
 *
 * NEON SIMD (new)
 *   Uses ARM NEON intrinsics directly (<arm_neon.h>) to issue vectorised
 *   FMA instructions:
 *     FP32: vfmaq_f32  -- 4x float32 per instruction (128-bit)
 *     FP64: vfmaq_f64  -- 2x float64 per instruction (128-bit)
 *     INT: vmulq_s32 + vaddq_s32 -- 4x int32 multiply-add
 *   8 independent vector accumulators are maintained per loop to exploit
 *   ILP across the 4 NEON execution units on P-cores. Each iteration
 *   performs 8 vector FMAs, so:
 *     FP32: 8 * 4 elements * 2 FLOP = 64 FLOP/iter
 *     FP64: 8 * 2 elements * 2 FLOP = 32 FLOP/iter
 *     INT32: 8 * 4 elements * 2 OPS = 64 OPS/iter
 *   This is 4x (FP32/INT) or 2x (FP64) the scalar result and represents
 *   what vectorized application code achieves.
 *
 * OUTPUT FORMAT
 *   Fixed-width labels for easy diffing between machines.
 */

#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <math.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <arm_neon.h>

static double g_ticks_to_ns;

static void init_timer(void) {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    g_ticks_to_ns = (double)info.numer / (double)info.denom;
}

static inline uint64_t ticks(void) { return mach_absolute_time(); }
static inline double ticks_to_sec(uint64_t t) { return t * g_ticks_to_ns / 1e9; }

static int get_sysctl_int(const char *name) {
    int val = 0; size_t len = sizeof(val);
    sysctlbyname(name, &val, &len, NULL, 0);
    return val;
}

/* ------------------------------------------------------------------ */
/* Scalar benchmarks                                                   */
/* ------------------------------------------------------------------ */
#define FP_ITERS (100L * 1000 * 1000)

typedef struct {
    double gops;
} compute_arg_t;

static void *fp32_scalar_thread(void *arg) {
    compute_arg_t *a = (compute_arg_t *)arg;
    float a0=1.0001f, a1=1.0002f, a2=1.0003f, a3=1.0004f;
    float a4=1.0005f, a5=1.0006f, a6=1.0007f, a7=1.0008f;
    float m = 1.000001f;

    uint64_t t0 = ticks();
    for (long i = 0; i < FP_ITERS; i++) {
        a0 = a0 * m + m; a1 = a1 * m + m;
        a2 = a2 * m + m; a3 = a3 * m + m;
        a4 = a4 * m + m; a5 = a5 * m + m;
        a6 = a6 * m + m; a7 = a7 * m + m;
    }
    uint64_t t1 = ticks();
    volatile float sink = a0+a1+a2+a3+a4+a5+a6+a7; (void)sink;
    a->gops = ((double)FP_ITERS * 8.0 * 2.0) / ticks_to_sec(t1-t0) / 1e9;
    return NULL;
}

static void *fp64_scalar_thread(void *arg) {
    compute_arg_t *a = (compute_arg_t *)arg;
    double a0=1.0001, a1=1.0002, a2=1.0003, a3=1.0004;
    double a4=1.0005, a5=1.0006, a6=1.0007, a7=1.0008;
    double m = 1.000001;

    uint64_t t0 = ticks();
    for (long i = 0; i < FP_ITERS; i++) {
        a0 = a0 * m + m; a1 = a1 * m + m;
        a2 = a2 * m + m; a3 = a3 * m + m;
        a4 = a4 * m + m; a5 = a5 * m + m;
        a6 = a6 * m + m; a7 = a7 * m + m;
    }
    uint64_t t1 = ticks();
    volatile double sink = a0+a1+a2+a3+a4+a5+a6+a7; (void)sink;
    a->gops = ((double)FP_ITERS * 8.0 * 2.0) / ticks_to_sec(t1-t0) / 1e9;
    return NULL;
}

static void *int64_scalar_thread(void *arg) {
    compute_arg_t *a = (compute_arg_t *)arg;
    long long a0=1, a1=3, a2=5, a3=7, a4=11, a5=13, a6=17, a7=19;
    long long m = 31;

    uint64_t t0 = ticks();
    for (long i = 0; i < FP_ITERS; i++) {
        a0 = a0 * m + i; a1 = a1 * m + i;
        a2 = a2 * m + i; a3 = a3 * m + i;
        a4 = a4 * m + i; a5 = a5 * m + i;
        a6 = a6 * m + i; a7 = a7 * m + i;
    }
    uint64_t t1 = ticks();
    volatile long long sink = a0+a1+a2+a3+a4+a5+a6+a7; (void)sink;
    a->gops = ((double)FP_ITERS * 8.0 * 2.0) / ticks_to_sec(t1-t0) / 1e9;
    return NULL;
}

/* ------------------------------------------------------------------ */
/* NEON SIMD benchmarks                                                */
/* ------------------------------------------------------------------ */

/*
 * FP32 SIMD: vfmaq_f32 (a = a * b + c)
 * 8 independent float32x4 accumulators -> 8 * 4 = 32 elements/iter
 * 2 FLOP per element (mul + add) -> 64 FLOP/iter
 */
static void *fp32_neon_thread(void *arg) {
    compute_arg_t *a = (compute_arg_t *)arg;

    float32x4_t v0 = vdupq_n_f32(1.0001f);
    float32x4_t v1 = vdupq_n_f32(1.0002f);
    float32x4_t v2 = vdupq_n_f32(1.0003f);
    float32x4_t v3 = vdupq_n_f32(1.0004f);
    float32x4_t v4 = vdupq_n_f32(1.0005f);
    float32x4_t v5 = vdupq_n_f32(1.0006f);
    float32x4_t v6 = vdupq_n_f32(1.0007f);
    float32x4_t v7 = vdupq_n_f32(1.0008f);
    float32x4_t m  = vdupq_n_f32(1.000001f);

    uint64_t t0 = ticks();
    for (long i = 0; i < FP_ITERS; i++) {
        v0 = vfmaq_f32(m, v0, m);
        v1 = vfmaq_f32(m, v1, m);
        v2 = vfmaq_f32(m, v2, m);
        v3 = vfmaq_f32(m, v3, m);
        v4 = vfmaq_f32(m, v4, m);
        v5 = vfmaq_f32(m, v5, m);
        v6 = vfmaq_f32(m, v6, m);
        v7 = vfmaq_f32(m, v7, m);
    }
    uint64_t t1 = ticks();

    /* Sink to prevent DCE */
    float32x4_t s = vaddq_f32(vaddq_f32(vaddq_f32(v0, v1), vaddq_f32(v2, v3)),
                               vaddq_f32(vaddq_f32(v4, v5), vaddq_f32(v6, v7)));
    volatile float sink = vgetq_lane_f32(s, 0); (void)sink;

    /* 8 vec FMAs/iter * 4 lanes * 2 FLOP/lane */
    a->gops = ((double)FP_ITERS * 8.0 * 4.0 * 2.0) / ticks_to_sec(t1-t0) / 1e9;
    return NULL;
}

/*
 * FP64 SIMD: vfmaq_f64 (a = a * b + c)
 * 8 independent float64x2 accumulators -> 8 * 2 = 16 elements/iter
 * 2 FLOP per element -> 32 FLOP/iter
 */
static void *fp64_neon_thread(void *arg) {
    compute_arg_t *a = (compute_arg_t *)arg;

    float64x2_t v0 = vdupq_n_f64(1.0001);
    float64x2_t v1 = vdupq_n_f64(1.0002);
    float64x2_t v2 = vdupq_n_f64(1.0003);
    float64x2_t v3 = vdupq_n_f64(1.0004);
    float64x2_t v4 = vdupq_n_f64(1.0005);
    float64x2_t v5 = vdupq_n_f64(1.0006);
    float64x2_t v6 = vdupq_n_f64(1.0007);
    float64x2_t v7 = vdupq_n_f64(1.0008);
    float64x2_t m  = vdupq_n_f64(1.000001);

    uint64_t t0 = ticks();
    for (long i = 0; i < FP_ITERS; i++) {
        v0 = vfmaq_f64(m, v0, m);
        v1 = vfmaq_f64(m, v1, m);
        v2 = vfmaq_f64(m, v2, m);
        v3 = vfmaq_f64(m, v3, m);
        v4 = vfmaq_f64(m, v4, m);
        v5 = vfmaq_f64(m, v5, m);
        v6 = vfmaq_f64(m, v6, m);
        v7 = vfmaq_f64(m, v7, m);
    }
    uint64_t t1 = ticks();

    float64x2_t s = vaddq_f64(vaddq_f64(vaddq_f64(v0, v1), vaddq_f64(v2, v3)),
                               vaddq_f64(vaddq_f64(v4, v5), vaddq_f64(v6, v7)));
    volatile double sink = vgetq_lane_f64(s, 0); (void)sink;

    /* 8 vec FMAs/iter * 2 lanes * 2 FLOP/lane */
    a->gops = ((double)FP_ITERS * 8.0 * 2.0 * 2.0) / ticks_to_sec(t1-t0) / 1e9;
    return NULL;
}

/*
 * INT32 SIMD: vmulq_s32 + vaddq_s32
 * 8 independent int32x4 accumulators -> 8 * 4 = 32 elements/iter
 * 2 OPS per element (mul + add) -> 64 OPS/iter
 * Note: ARM64 integer multiply is throughput-1/cycle but latency-3.
 * 8 independent chains keep the pipeline fed.
 */
static void *int32_neon_thread(void *arg) {
    compute_arg_t *a = (compute_arg_t *)arg;

    int32x4_t v0 = vdupq_n_s32(1);
    int32x4_t v1 = vdupq_n_s32(3);
    int32x4_t v2 = vdupq_n_s32(5);
    int32x4_t v3 = vdupq_n_s32(7);
    int32x4_t v4 = vdupq_n_s32(11);
    int32x4_t v5 = vdupq_n_s32(13);
    int32x4_t v6 = vdupq_n_s32(17);
    int32x4_t v7 = vdupq_n_s32(19);
    int32x4_t m  = vdupq_n_s32(31);

    uint64_t t0 = ticks();
    for (long i = 0; i < FP_ITERS; i++) {
        v0 = vaddq_s32(vmulq_s32(v0, m), m);
        v1 = vaddq_s32(vmulq_s32(v1, m), m);
        v2 = vaddq_s32(vmulq_s32(v2, m), m);
        v3 = vaddq_s32(vmulq_s32(v3, m), m);
        v4 = vaddq_s32(vmulq_s32(v4, m), m);
        v5 = vaddq_s32(vmulq_s32(v5, m), m);
        v6 = vaddq_s32(vmulq_s32(v6, m), m);
        v7 = vaddq_s32(vmulq_s32(v7, m), m);
    }
    uint64_t t1 = ticks();

    int32x4_t s = vaddq_s32(vaddq_s32(vaddq_s32(v0, v1), vaddq_s32(v2, v3)),
                             vaddq_s32(vaddq_s32(v4, v5), vaddq_s32(v6, v7)));
    volatile int sink = vgetq_lane_s32(s, 0); (void)sink;

    /* 8 iters * 4 lanes * 2 OPS */
    a->gops = ((double)FP_ITERS * 8.0 * 4.0 * 2.0) / ticks_to_sec(t1-t0) / 1e9;
    return NULL;
}

/* ------------------------------------------------------------------ */
/* Runner                                                              */
/* ------------------------------------------------------------------ */
typedef void *(*thread_fn)(void *);

static double run_compute(thread_fn fn, int nthreads) {
    pthread_t *tids = calloc(nthreads, sizeof(pthread_t));
    compute_arg_t *args = calloc(nthreads, sizeof(compute_arg_t));

    for (int i = 0; i < nthreads; i++)
        pthread_create(&tids[i], NULL, fn, &args[i]);

    double total = 0;
    for (int i = 0; i < nthreads; i++) {
        pthread_join(tids[i], NULL);
        total += args[i].gops;
    }

    free(tids);
    free(args);
    return total;
}

int main(int argc, char **argv) {
    init_timer();

    int nthreads = get_sysctl_int("hw.ncpu");
    if (nthreads <= 0) nthreads = 4;
    if (argc >= 2) nthreads = atoi(argv[1]);

    char brand[256] = "unknown";
    size_t len = sizeof(brand);
    sysctlbyname("machdep.cpu.brand_string", brand, &len, NULL, 0);

    printf("========================================================\n");
    printf("  CPU Compute Throughput Benchmark\n");
    printf("========================================================\n\n");
    printf("CPU:             %s\n", brand);
    printf("Threads:         %d\n\n", nthreads);

    /* Single-threaded */
    printf("--- Scalar FMA (single-threaded) ---\n");
    printf("  %-28s  %8.2f GFLOPS\n", "FP32 scalar FMA:", run_compute(fp32_scalar_thread, 1));
    printf("  %-28s  %8.2f GFLOPS\n", "FP64 scalar FMA:", run_compute(fp64_scalar_thread, 1));
    printf("  %-28s  %8.2f GOPS\n",   "INT64 scalar mul+add:", run_compute(int64_scalar_thread, 1));

    printf("\n--- NEON SIMD (single-threaded) ---\n");
    printf("  %-28s  %8.2f GFLOPS\n", "FP32 NEON FMA (4-wide):", run_compute(fp32_neon_thread, 1));
    printf("  %-28s  %8.2f GFLOPS\n", "FP64 NEON FMA (2-wide):", run_compute(fp64_neon_thread, 1));
    printf("  %-28s  %8.2f GOPS\n",   "INT32 NEON mul+add (4-wide):", run_compute(int32_neon_thread, 1));

    /* Multi-threaded */
    printf("\n--- Scalar FMA (multi-threaded, %d threads) ---\n", nthreads);
    printf("  %-28s  %8.2f GFLOPS\n", "FP32 scalar FMA:", run_compute(fp32_scalar_thread, nthreads));
    printf("  %-28s  %8.2f GFLOPS\n", "FP64 scalar FMA:", run_compute(fp64_scalar_thread, nthreads));
    printf("  %-28s  %8.2f GOPS\n",   "INT64 scalar mul+add:", run_compute(int64_scalar_thread, nthreads));

    printf("\n--- NEON SIMD (multi-threaded, %d threads) ---\n", nthreads);
    printf("  %-28s  %8.2f GFLOPS\n", "FP32 NEON FMA (4-wide):", run_compute(fp32_neon_thread, nthreads));
    printf("  %-28s  %8.2f GFLOPS\n", "FP64 NEON FMA (2-wide):", run_compute(fp64_neon_thread, nthreads));
    printf("  %-28s  %8.2f GOPS\n",   "INT32 NEON mul+add (4-wide):", run_compute(int32_neon_thread, nthreads));

    printf("\n========================================================\n");
    return 0;
}
