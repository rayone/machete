/*
 * cpu_membench.c - CPU Memory Bandwidth & Latency Benchmark
 *
 * Build: cc -O2 -pthread -o cpu_membench cpu_membench.c
 * Usage: ./cpu_membench [buffer_size_mb] [num_threads]
 *        Defaults: 512 MB buffer, all cores
 *
 * === METHODOLOGY ===
 *
 * BANDWIDTH TESTS
 *   Three operations: write, read, copy. Each is run for 6 iterations and
 *   the peak (burst) result is reported. A sustained test then runs for
 *   30 seconds continuously, sampling bandwidth every second, to reveal
 *   thermal throttling -- the gap between burst and sustained tells you
 *   whether the machine can maintain peak bandwidth under load.
 *
 * PER-THREAD BREAKDOWN
 *   Runs a single-threaded bandwidth test on P-core count and E-core count
 *   threads separately (using affinity tags to hint placement). Lets you
 *   compare per-core contributions across different machine configurations.
 *
 * LATENCY TESTS
 *   Two pointer-chase measurements:
 *   - DRAM latency:  512 MB region, 256-byte stride (existing)
 *   - TLB miss latency: 512 MB region, 4096-byte stride so that every
 *     access maps to a distinct 16 KB page. At 512 MB / 16 KB = 32768
 *     pages, this far exceeds the L2 TLB (~2048 entries), so each access
 *     incurs a TLB miss ON TOP of a DRAM miss. The difference between
 *     DRAM latency and TLB latency isolates the TLB-walk overhead.
 *
 * OUTPUT FORMAT
 *   All lines use fixed-width labels and numeric fields for easy diffing
 *   between machines with `diff` or `vimdiff`.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include <mach/mach.h>
#include <mach/thread_policy.h>
#include <mach/thread_act.h>
#include <sys/sysctl.h>

/* ------------------------------------------------------------------ */
/* Timing helpers                                                      */
/* ------------------------------------------------------------------ */
static double g_ticks_to_ns;

static void init_timer(void) {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    g_ticks_to_ns = (double)info.numer / (double)info.denom;
}

static inline uint64_t ticks(void) { return mach_absolute_time(); }
static inline double ticks_to_sec(uint64_t t) { return t * g_ticks_to_ns / 1e9; }

static inline void barrier(void *p, size_t n) {
    __asm__ __volatile__("" : : "r"(p), "r"(n) : "memory");
}

/* ------------------------------------------------------------------ */
/* System info                                                         */
/* ------------------------------------------------------------------ */
static int get_sysctl_int(const char *name) {
    int val = 0;
    size_t len = sizeof(val);
    if (sysctlbyname(name, &val, &len, NULL, 0) != 0) return -1;
    return val;
}

static long long get_sysctl_ll(const char *name) {
    long long val = 0;
    size_t len = sizeof(val);
    if (sysctlbyname(name, &val, &len, NULL, 0) != 0) return -1;
    return val;
}

static void get_sysctl_str(const char *name, char *buf, size_t bufsz) {
    size_t len = bufsz;
    if (sysctlbyname(name, buf, &len, NULL, 0) != 0)
        snprintf(buf, bufsz, "unknown");
}

static void print_system_info(void) {
    char brand[256];
    get_sysctl_str("machdep.cpu.brand_string", brand, sizeof(brand));

    int ncpu = get_sysctl_int("hw.ncpu");
    int pcpu = get_sysctl_int("hw.physicalcpu");
    long long memsize = get_sysctl_ll("hw.memsize");

    printf("CPU:                 %s\n", brand);
    printf("Cores:               %d physical, %d logical\n", pcpu, ncpu);
    printf("RAM:                 %.1f GB\n", memsize / (1024.0*1024.0*1024.0));
}

/* ------------------------------------------------------------------ */
/* Thread work                                                         */
/* ------------------------------------------------------------------ */
typedef enum { OP_READ, OP_WRITE, OP_COPY } op_t;

typedef struct {
    char     *src;
    char     *dst;
    long      size;
    op_t      op;
    double    elapsed_s;
    int       iter;
    int       affinity_tag;   /* 0 = no hint */
} thread_arg_t;

static void set_affinity_tag(int tag) {
    if (tag <= 0) return;
    thread_affinity_policy_data_t policy = { tag };
    thread_policy_set(mach_thread_self(), THREAD_AFFINITY_POLICY,
                      (thread_policy_t)&policy, 1);
}

static void *thread_func(void *arg) {
    thread_arg_t *a = (thread_arg_t *)arg;
    set_affinity_tag(a->affinity_tag);

    long count = a->size / (long)sizeof(long long);
    uint64_t t0, t1;

    switch (a->op) {
    case OP_WRITE: {
        volatile long long *d = (volatile long long *)a->dst;
        long long val = 0x0101010101010101LL * (long long)a->iter;
        t0 = ticks();
        for (long j = 0; j < count; j += 8) {
            d[j]=val; d[j+1]=val; d[j+2]=val; d[j+3]=val;
            d[j+4]=val; d[j+5]=val; d[j+6]=val; d[j+7]=val;
        }
        t1 = ticks();
        break;
    }
    case OP_READ: {
        long long *s = (long long *)a->src;
        volatile long long sum = 0;
        t0 = ticks();
        for (long j = 0; j < count; j += 8) {
            sum += s[j]+s[j+1]+s[j+2]+s[j+3]+s[j+4]+s[j+5]+s[j+6]+s[j+7];
        }
        t1 = ticks();
        (void)sum;
        break;
    }
    case OP_COPY: {
        long long *s = (long long *)a->src;
        volatile long long *d = (volatile long long *)a->dst;
        t0 = ticks();
        for (long j = 0; j < count; j += 8) {
            d[j]=s[j]; d[j+1]=s[j+1]; d[j+2]=s[j+2]; d[j+3]=s[j+3];
            d[j+4]=s[j+4]; d[j+5]=s[j+5]; d[j+6]=s[j+6]; d[j+7]=s[j+7];
        }
        t1 = ticks();
        break;
    }
    }
    a->elapsed_s = ticks_to_sec(t1 - t0);
    return NULL;
}

/* Run one bandwidth pass; return GB/s */
static double run_bw_once(op_t op, char *src, char *dst, long total,
                           int nthreads, int base_affinity_tag)
{
    pthread_t *tids = calloc(nthreads, sizeof(pthread_t));
    thread_arg_t *args = calloc(nthreads, sizeof(thread_arg_t));
    long chunk = (total / nthreads) & ~63L;

    barrier(src, total);
    barrier(dst, total);

    for (int t = 0; t < nthreads; t++) {
        args[t].src  = src + t * chunk;
        args[t].dst  = dst + t * chunk;
        args[t].size = chunk;
        args[t].op   = op;
        args[t].iter = t;
        args[t].affinity_tag = (base_affinity_tag > 0) ? base_affinity_tag + t : 0;
        pthread_create(&tids[t], NULL, thread_func, &args[t]);
    }

    double max_elapsed = 0;
    for (int t = 0; t < nthreads; t++) {
        pthread_join(tids[t], NULL);
        if (args[t].elapsed_s > max_elapsed)
            max_elapsed = args[t].elapsed_s;
    }

    double data_gb = (double)(chunk * nthreads) / (1024.0*1024.0*1024.0);
    double bw = (op == OP_COPY) ? (2.0 * data_gb) / max_elapsed
                                :        data_gb   / max_elapsed;
    free(tids);
    free(args);
    return bw;
}

/* Run `iters` times, return peak (burst) GB/s.
 * base_affinity_tag: if > 0, threads get tags base..base+nthreads-1
 *                    to hint core placement (P-core vs E-core). */
static double run_bw_burst(op_t op, char *src, char *dst, long total,
                            int nthreads, int iters, int base_affinity_tag)
{
    double best = 0;
    for (int i = 0; i < iters; i++) {
        double bw = run_bw_once(op, src, dst, total, nthreads, base_affinity_tag);
        if (bw > best) best = bw;
    }
    return best;
}

/*
 * Sustained bandwidth test.
 * Runs continuously for `duration_sec`, sampling each pass.
 * Prints: burst (first 3s), sustained average, min sample, throttle ratio.
 */
static void run_bw_sustained(op_t op, char *src, char *dst, long total,
                              int nthreads, int duration_sec,
                              const char *label)
{
    double burst = 0;
    double sum = 0;
    double min_bw = 1e9;
    int count = 0;
    double burst_window = 0;
    int burst_samples = 0;

    uint64_t wall_start = ticks();
    double elapsed = 0;

    while (elapsed < (double)duration_sec) {
        double bw = run_bw_once(op, src, dst, total, nthreads, 0);
        sum += bw;
        count++;
        if (bw < min_bw) min_bw = bw;

        elapsed = ticks_to_sec(ticks() - wall_start);

        /* Average of first 3 seconds = burst window */
        if (elapsed <= 3.0) {
            burst_window += bw;
            burst_samples++;
        }
    }

    if (burst_samples > 0)
        burst = burst_window / burst_samples;

    double avg = sum / count;
    double throttle_pct = (burst > 0) ? (avg / burst) * 100.0 : 100.0;

    printf("  %-36s  burst %7.2f GB/s  sustained %7.2f GB/s  min %7.2f GB/s  throttle %5.1f%%\n",
           label, burst, avg, min_bw, throttle_pct);
}

/* ------------------------------------------------------------------ */
/* Latency benchmarks                                                  */
/* ------------------------------------------------------------------ */

/*
 * Classic random pointer-chase.
 * stride: spacing between nodes in bytes.
 *   - 256 B  -> many nodes per page -> measures DRAM latency (no TLB pressure)
 *   - 16384 B -> one node per 16 KB page -> measures DRAM + TLB miss latency
 */
static double run_latency(char *buf, long size, long stride) {
    long nnodes = size / stride;
    if (nnodes < 16) return 0;
    long *base = (long *)buf;

    long *order = malloc(nnodes * sizeof(long));
    for (long i = 0; i < nnodes; i++) order[i] = i;
    srand(12345);
    for (long i = nnodes - 1; i > 0; i--) {
        long j = rand() % (i + 1);
        long tmp = order[i]; order[i] = order[j]; order[j] = tmp;
    }
    for (long i = 0; i < nnodes - 1; i++)
        base[order[i] * (stride / sizeof(long))] = order[i+1] * (stride / sizeof(long));
    base[order[nnodes-1] * (stride / sizeof(long))] = order[0] * (stride / sizeof(long));
    free(order);

    /* Warmup */
    long idx = 0;
    for (long i = 0; i < nnodes; i++) idx = base[idx];

    /* Cap chase count to keep runtime reasonable */
    long chase_count = nnodes * 4;
    if (chase_count < 500000)  chase_count = 500000;
    if (chase_count > 50000000) chase_count = 50000000;

    uint64_t t0 = ticks();
    idx = 0;
    for (long i = 0; i < chase_count; i++) idx = base[idx];
    uint64_t t1 = ticks();
    volatile long dummy = idx; (void)dummy;

    return ((t1 - t0) * g_ticks_to_ns) / (double)chase_count;
}

/* ------------------------------------------------------------------ */
/* Main                                                                */
/* ------------------------------------------------------------------ */
int main(int argc, char **argv) {
    init_timer();

    long buf_mb = 512;
    int  nthreads = get_sysctl_int("hw.ncpu");
    if (nthreads <= 0) nthreads = 4;

    if (argc >= 2) buf_mb = atol(argv[1]);
    if (argc >= 3) nthreads = atoi(argv[2]);
    if (buf_mb < 64) buf_mb = 64;
    if (nthreads < 1) nthreads = 1;

    long total = buf_mb * 1024L * 1024L;
    int burst_iters = 6;
    int sustained_sec = 30;

    /* Get core type counts for per-type breakdown */
    int nperf    = get_sysctl_int("hw.nperflevels");
    int p_cores  = (nperf >= 1) ? get_sysctl_int("hw.perflevel0.physicalcpu") : 0;
    int e_cores  = (nperf >= 2) ? get_sysctl_int("hw.perflevel1.physicalcpu") : 0;

    printf("========================================================\n");
    printf("  CPU Memory Bandwidth & Latency Benchmark\n");
    printf("========================================================\n\n");

    print_system_info();

    printf("\nBuffer: %ld MB   Threads: %d   Burst iters: %d   Sustained: %d s\n\n",
           buf_mb, nthreads, burst_iters, sustained_sec);

    char *src, *dst;
    posix_memalign((void **)&src, 4096, total);
    posix_memalign((void **)&dst, 4096, total);
    if (!src || !dst) { fprintf(stderr, "Allocation failed\n"); return 1; }

    memset(src, 'A', total);
    memset(dst, 'B', total);
    barrier(src, total);
    barrier(dst, total);

    /* ---- Burst bandwidth ---- */
    printf("--- Burst Bandwidth (peak of %d iterations) ---\n", burst_iters);

    printf("  %-28s  %8.2f GB/s\n", "Single-thread write:",
           run_bw_burst(OP_WRITE, src, dst, total, 1, burst_iters, 0));
    printf("  %-28s  %8.2f GB/s\n", "Single-thread read:",
           run_bw_burst(OP_READ,  src, dst, total, 1, burst_iters, 0));
    printf("  %-28s  %8.2f GB/s\n", "Single-thread copy:",
           run_bw_burst(OP_COPY,  src, dst, total, 1, burst_iters, 0));

    printf("\n");
    printf("  %-28s  %8.2f GB/s\n", "Multi-thread write:",
           run_bw_burst(OP_WRITE, src, dst, total, nthreads, burst_iters, 0));
    printf("  %-28s  %8.2f GB/s\n", "Multi-thread read:",
           run_bw_burst(OP_READ,  src, dst, total, nthreads, burst_iters, 0));
    printf("  %-28s  %8.2f GB/s\n", "Multi-thread copy:",
           run_bw_burst(OP_COPY,  src, dst, total, nthreads, burst_iters, 0));

    /* ---- Per-core-type bandwidth ---- */
    if (p_cores > 0 && e_cores > 0) {
        printf("\n--- Per-Core-Type Bandwidth (burst, %d iters) ---\n", burst_iters);
        printf("  (Affinity tags used as hints; not guaranteed to pin to specific core type)\n");

        /* P-cores: use low tags (1..p_cores) -- user-interactive QoS favors P-cores */
        printf("  %-28s  %8.2f GB/s\n", "P-cores only write:",
               run_bw_burst(OP_WRITE, src, dst, total, p_cores, burst_iters, 1));
        printf("  %-28s  %8.2f GB/s\n", "P-cores only read:",
               run_bw_burst(OP_READ,  src, dst, total, p_cores, burst_iters, 1));
        printf("  %-28s  %8.2f GB/s\n", "P-cores only copy:",
               run_bw_burst(OP_COPY,  src, dst, total, p_cores, burst_iters, 1));

        printf("\n");
        /* E-cores: use high tags (100..100+e_cores) to separate from P-core group */
        printf("  %-28s  %8.2f GB/s\n", "E-cores only write:",
               run_bw_burst(OP_WRITE, src, dst, total, e_cores, burst_iters, 100));
        printf("  %-28s  %8.2f GB/s\n", "E-cores only read:",
               run_bw_burst(OP_READ,  src, dst, total, e_cores, burst_iters, 100));
        printf("  %-28s  %8.2f GB/s\n", "E-cores only copy:",
               run_bw_burst(OP_COPY,  src, dst, total, e_cores, burst_iters, 100));
    }

    /* ---- Sustained bandwidth ---- */
    printf("\n--- Sustained Bandwidth (%d seconds, all %d threads) ---\n",
           sustained_sec, nthreads);
    printf("  Format: burst (avg first 3s)  sustained (full avg)  min  throttle%%\n\n");

    run_bw_sustained(OP_WRITE, src, dst, total, nthreads, sustained_sec,
                     "Multi-thread write:");
    run_bw_sustained(OP_READ,  src, dst, total, nthreads, sustained_sec,
                     "Multi-thread read:");
    run_bw_sustained(OP_COPY,  src, dst, total, nthreads, sustained_sec,
                     "Multi-thread copy:");

    /* ---- Latency ---- */
    printf("\n--- Random Access Latency ---\n");

    double lat_dram = run_latency(src, total, 256);
    printf("  %-36s  %8.2f ns  (DRAM latency, 256B stride)\n",
           "Pointer chase (DRAM):", lat_dram);

    /*
     * TLB miss test: stride = 16384 bytes (one access per 16 KB page).
     * 512 MB / 16 KB = 32768 unique pages >> L2 TLB (~2048 entries).
     * Each chase step incurs both a TLB miss and a DRAM miss.
     */
    double lat_tlb = run_latency(src, total, 16384);
    printf("  %-36s  %8.2f ns  (DRAM + TLB miss, 16384B stride)\n",
           "Pointer chase (TLB miss):", lat_tlb);
    printf("  %-36s  %8.2f ns  (TLB walk overhead = TLB - DRAM)\n",
           "TLB walk overhead:", lat_tlb - lat_dram);

    printf("\n========================================================\n");
    free(src);
    free(dst);
    return 0;
}
