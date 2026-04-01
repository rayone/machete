/*
 * cache_bench.c - CPU Cache Hierarchy Benchmark
 *
 * Build: cc -O2 -pthread -o cache_bench cache_bench.c
 * Usage: ./cache_bench
 *
 * === METHODOLOGY ===
 *
 * WHAT THIS MEASURES
 *   Read bandwidth and random-access latency as a function of working-set
 *   size, sweeping from 4 KB to 1 GB. The resulting curve reveals the
 *   bandwidth and latency at each level of the cache hierarchy: L1d, L2,
 *   and main memory (DRAM). Transition points between levels appear as
 *   bandwidth drops or latency steps.
 *
 * BANDWIDTH MEASUREMENT
 *   For each buffer size, a sequential read loop sums 8 consecutive
 *   int64 values per iteration (64 bytes per iteration, matching a
 *   typical cache line on x86; on Apple Silicon the 128-byte cache line
 *   means two loop iterations per line). The sum is stored in a volatile
 *   to prevent dead-code elimination.
 *
 *   To get stable timing at small buffer sizes, the loop repeats enough
 *   passes to transfer at least 256 MB total (or 4x the buffer size,
 *   whichever is larger). For a 4 KB buffer, this is ~65,000 passes. A
 *   compiler barrier (__asm__ volatile with "memory" clobber) between
 *   passes prevents the compiler from hoisting loads out of the loop,
 *   though it does NOT flush caches -- the point is to re-read from
 *   cache. A single warmup pass runs before timing to populate caches.
 *
 *   RESULT INTERPRETATION: Small buffers fit entirely in L1d (128 KB on
 *   P-core, 64 KB on E-core), so you see peak bandwidth (~100+ GB/s).
 *   Buffers exceeding L1d but fitting in L2 see slightly lower BW. Once
 *   the buffer exceeds L2 (16 MB P-core / 8 MB E-core), bandwidth drops
 *   to DRAM speed. On Apple Silicon, the hardware prefetcher is very
 *   effective for sequential access, so the DRAM bandwidth "cliff" may
 *   be less dramatic than on other architectures -- the prefetcher can
 *   hide DRAM latency for streaming reads.
 *
 * LATENCY MEASUREMENT
 *   Same pointer-chase technique as cpu_membench.c. For each buffer size:
 *   1. Build a random cyclic linked list using Fisher-Yates shuffle
 *   2. Stride is 128 bytes (one Apple Silicon cache line per node)
 *   3. Chase pointers: idx = base[idx] in a tight loop
 *   4. The random order defeats spatial, stride, and stream prefetchers
 *   5. Each load depends on the previous (serial dependency chain)
 *   6. Warmup traversal populates TLB entries
 *   7. Chase count is max(8 * num_nodes, 1M) capped at 100M
 *
 *   At small buffer sizes (fit in L1), latency is ~0.9 ns (~4 cycles at
 *   ~4.5 GHz). L2 latency is ~2.5-3 ns. DRAM is ~110 ns. The step
 *   function in latency vs. size directly reveals cache sizes.
 *
 * SINGLE-THREADED
 *   This benchmark runs on a single thread with no affinity pinning.
 *   macOS will schedule it on whichever core it chooses (typically a
 *   P-core for short bursts). This means results reflect the cache
 *   hierarchy of whichever core type runs it. For consistent results,
 *   run multiple times and note that P-core L1d=128KB, E-core L1d=64KB
 *   -- the bandwidth step location reveals which core type was used.
 *
 * KNOWN LIMITATIONS
 *   - NO CORE PINNING: Cannot guarantee P-core vs E-core execution. The
 *     latency curve may show L1d->L2 transition at 64KB or 128KB
 *     depending on which core the OS scheduled.
 *   - PREFETCHER EFFECTS ON BANDWIDTH: Apple Silicon's L2 prefetcher
 *     aggressively prefetches sequential streams. For bandwidth, even
 *     buffers larger than L2 may show near-L2 bandwidth because the
 *     prefetcher keeps the pipeline fed. Latency is the more reliable
 *     indicator of cache level since it uses random access.
 *   - TLB EFFECTS: Very large buffers (>256 MB) may show TLB miss
 *     overhead on top of DRAM latency. With 16 KB pages and a ~2K-entry
 *     L2 TLB, coverage is ~32 MB; beyond that, TLB misses add ~5-10 ns.
 *   - SHARED L2: Apple Silicon shares L2 among a cluster of cores (e.g.,
 *     6 P-cores share 16 MB). Background activity from other processes
 *     on sibling cores can evict cache lines, reducing effective L2 size.
 *   - 1 GB ALLOCATION: The test allocates 1 GB up front. On machines
 *     with limited RAM this may cause swap pressure.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>

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

static int get_sysctl_int(const char *name) {
    int val = 0; size_t len = sizeof(val);
    sysctlbyname(name, &val, &len, NULL, 0);
    return val;
}

/*
 * Measure sequential read bandwidth for a given buffer size.
 * We do enough passes to read at least 256 MB total, for stable timing.
 */
static double measure_read_bw(char *buf, long size) {
    long total_bytes_target = 256L * 1024 * 1024;
    if (total_bytes_target < size * 4) total_bytes_target = size * 4;
    long passes = total_bytes_target / size;
    if (passes < 2) passes = 2;

    long long *p = (long long *)buf;
    long count = size / (long)sizeof(long long);

    /* Warmup */
    volatile long long sum = 0;
    for (long j = 0; j < count; j += 8)
        sum += p[j]+p[j+1]+p[j+2]+p[j+3]+p[j+4]+p[j+5]+p[j+6]+p[j+7];

    barrier(buf, size);

    uint64_t t0 = ticks();
    for (long pass = 0; pass < passes; pass++) {
        sum = 0;
        for (long j = 0; j < count; j += 8)
            sum += p[j]+p[j+1]+p[j+2]+p[j+3]+p[j+4]+p[j+5]+p[j+6]+p[j+7];
        barrier(buf, size);
    }
    uint64_t t1 = ticks();

    (void)sum;
    double sec = ticks_to_sec(t1 - t0);
    double bytes = (double)size * passes;
    return (bytes / (1024.0*1024.0*1024.0)) / sec;  /* GB/s */
}

/*
 * Measure random access latency for a given buffer size via pointer chasing.
 */
static double measure_latency(char *buf, long size) {
    long stride = 128;  /* Apple Silicon cache line is 128 bytes */
    long nnodes = size / stride;
    if (nnodes < 16) return 0;

    long *base = (long *)buf;

    /* Build random linked list */
    long *order = malloc(nnodes * sizeof(long));
    for (long i = 0; i < nnodes; i++) order[i] = i;
    /* Fisher-Yates */
    srand(54321);
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

    long chase_count = nnodes * 8;
    if (chase_count < 1000000) chase_count = 1000000;
    if (chase_count > 100000000) chase_count = 100000000;

    uint64_t t0 = ticks();
    idx = 0;
    for (long i = 0; i < chase_count; i++) idx = base[idx];
    uint64_t t1 = ticks();

    volatile long dummy = idx; (void)dummy;
    return ((t1 - t0) * g_ticks_to_ns) / (double)chase_count;
}

int main(void) {
    init_timer();

    char brand[256] = "unknown";
    size_t len = sizeof(brand);
    sysctlbyname("machdep.cpu.brand_string", brand, &len, NULL, 0);

    printf("========================================================\n");
    printf("  CPU Cache Hierarchy Benchmark\n");
    printf("========================================================\n\n");
    printf("CPU:             %s\n", brand);

    int nperf = get_sysctl_int("hw.nperflevels");
    for (int lvl = 0; lvl < nperf; lvl++) {
        char key[128];
        const char *label = lvl == 0 ? "P-core" : "E-core";
        snprintf(key, sizeof(key), "hw.perflevel%d.l1dcachesize", lvl);
        int l1d = get_sysctl_int(key);
        snprintf(key, sizeof(key), "hw.perflevel%d.l2cachesize", lvl);
        int l2 = get_sysctl_int(key);
        if (l1d > 0)
            printf("  %-7s L1d: %d KB, L2: %d MB\n", label, l1d/1024, l2/(1024*1024));
    }

    printf("\nSweeping buffer sizes from 4 KB to 1 GB...\n");
    printf("(Single-threaded, running on whatever core the OS schedules)\n\n");
    printf("%-14s  %10s  %10s\n", "Buffer Size", "Read BW", "Latency");
    printf("%-14s  %10s  %10s\n", "-----------", "--------", "--------");

    /* Allocate maximum needed */
    long max_size = 1024L * 1024 * 1024;  /* 1 GB */
    char *buf;
    posix_memalign((void **)&buf, 4096, max_size);
    if (!buf) { fprintf(stderr, "alloc failed\n"); return 1; }
    memset(buf, 'A', max_size);
    barrier(buf, max_size);

    /* Sizes to test (in KB) */
    long sizes_kb[] = {
        4, 8, 16, 32, 48, 64, 96, 128,           /* within L1 */
        192, 256, 384, 512, 768, 1024,             /* L1 -> L2 */
        2*1024, 4*1024, 8*1024, 16*1024,           /* within L2 */
        24*1024, 32*1024, 48*1024, 64*1024,        /* L2 -> DRAM */
        128*1024, 256*1024, 512*1024, 1024*1024,   /* DRAM */
        0
    };

    for (int i = 0; sizes_kb[i] != 0; i++) {
        long size = sizes_kb[i] * 1024L;
        if (size > max_size) break;

        /* Ensure size is a multiple of 64 bytes */
        size = (size + 63) & ~63L;

        double bw = measure_read_bw(buf, size);
        double lat = measure_latency(buf, size);

        char label[32];
        if (sizes_kb[i] >= 1024)
            snprintf(label, sizeof(label), "%ld MB", sizes_kb[i] / 1024);
        else
            snprintf(label, sizeof(label), "%ld KB", sizes_kb[i]);

        printf("%-14s  %8.2f GB/s  %8.2f ns\n", label, bw, lat);
    }

    printf("\n========================================================\n");
    free(buf);
    return 0;
}
