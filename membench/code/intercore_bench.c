/*
 * intercore_bench.c - Inter-Core Latency Benchmark
 *
 * Build: cc -O2 -pthread -o intercore_bench intercore_bench.c
 * Usage: ./intercore_bench
 *
 * === METHODOLOGY ===
 *
 * WHAT THIS MEASURES
 *   Round-trip cache-line transfer latency between two CPU cores. This is
 *   the time for Core A to write a shared variable and Core B to observe
 *   the new value, plus the reverse. This measures the coherency protocol
 *   latency (MOESI/MESI state transitions) and interconnect speed between
 *   cores.
 *
 * TECHNIQUE: CACHE-LINE PING-PONG
 *   Two threads share a volatile int `flag`, aligned to 128 bytes (one
 *   Apple Silicon cache line) to prevent false sharing with adjacent data.
 *
 *   Thread A (ping): sets flag = 1, then spin-waits until flag == 0
 *   Thread B (pong): spin-waits until flag == 1, then sets flag = 0
 *
 *   Each round-trip requires:
 *     1. Thread A stores 1 -> cache line transitions to Modified on A's core
 *     2. Thread B's spin-load sees stale 0 until coherency protocol
 *        invalidates/updates B's copy. B reads the new value, pulling the
 *        line into B's cache (Shared/Exclusive state)
 *     3. Thread B stores 0 -> line transitions to Modified on B's core
 *     4. Thread A's spin-load eventually sees 0, completing the round-trip
 *
 *   The round-trip time divided by 2 approximates one-way latency, though
 *   the actual protocol may be asymmetric (snoop vs. intervention).
 *
 * THREAD PLACEMENT
 *   macOS does not support CPU affinity (binding a thread to a specific
 *   core). Instead, we use THREAD_AFFINITY_POLICY, which is an advisory
 *   hint: threads with DIFFERENT affinity tags are *preferred* to run on
 *   different cores, and threads with the SAME tag on the same core.
 *
 *   We test 6 different tag pairs to try to capture different core
 *   pairings (P-P, P-E, E-E, same-cluster, cross-cluster). Since we
 *   cannot control which specific cores are chosen, the results are
 *   best-effort. We report the best and worst observed latencies, which
 *   likely correspond to same-cluster and cross-cluster pairings.
 *
 *   A 10 ms usleep() after thread creation gives the scheduler time to
 *   migrate threads to their preferred cores. A 1000-iteration warmup
 *   follows before timed measurement.
 *
 * TIMING
 *   mach_absolute_time() brackets 2,000,000 ping-pong round-trips.
 *   Result = total_time / count. The large count amortizes any timer
 *   overhead to negligible levels.
 *
 * EXPECTED RESULTS
 *   - Same L2 cluster (e.g., two P-cores sharing 16 MB L2): ~30-40 ns
 *     round-trip, as the coherency is handled within the shared L2.
 *   - Cross-cluster (P-core to E-core, or between separate L2 clusters):
 *     ~80-120 ns round-trip, as the data must traverse the chip
 *     interconnect.
 *   - If both threads land on the same core (unlikely with different
 *     tags): very fast (<10 ns) as it's just L1 access.
 *
 * KNOWN LIMITATIONS
 *   - ADVISORY AFFINITY: The biggest limitation. macOS can ignore hints,
 *     especially under load. Two threads with different tags may still
 *     end up on the same core or same cluster. Results are probabilistic,
 *     not deterministic.
 *   - NO CORE IDENTIFICATION: We cannot determine WHICH cores were used
 *     for a given measurement. The labels ("Pair A", "Pair B") only
 *     indicate different tag combinations, not specific core IDs.
 *   - P-CORE BIAS: Default QoS for user-initiated threads biases toward
 *     P-cores. Cross-cluster measurements (P-E) require the scheduler
 *     to place one thread on an E-core, which may not happen consistently.
 *   - SPIN-WAIT OVERHEAD: The spin-loop may execute branch-prediction
 *     recovery cycles when the flag changes. This adds a small constant
 *     overhead (~1-2 ns) to each measurement, but it's consistent across
 *     all measurements so relative comparisons are valid.
 *   - VOLATILE != ATOMIC: The flag uses volatile int, not _Atomic. On
 *     ARM64, volatile stores are plain STR instructions (release semantics
 *     require STLR). In practice, the spin-loop's tight polling and the
 *     coherency protocol make this work correctly for ping-pong, but it
 *     is technically not guaranteed by the C standard. Using
 *     __atomic_store_n / __atomic_load_n with relaxed ordering would be
 *     more correct but may add overhead from barrier instructions.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <stdatomic.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>

/* macOS thread affinity is done via thread_policy_set */
#include <mach/mach.h>
#include <mach/thread_policy.h>
#include <mach/thread_act.h>

static double g_ticks_to_ns;

static void init_timer(void) {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    g_ticks_to_ns = (double)info.numer / (double)info.denom;
}

static inline uint64_t ticks(void) { return mach_absolute_time(); }

static int get_sysctl_int(const char *name) {
    int val = 0; size_t len = sizeof(val);
    sysctlbyname(name, &val, &len, NULL, 0);
    return val;
}

/*
 * Set thread affinity tag. On macOS this is advisory -- the kernel uses it
 * to group/separate threads. Two threads with DIFFERENT tags will be placed
 * on different cores. Same tag -> same core preference.
 * We also set QoS to user-interactive to prefer P-cores when desired.
 */
static void set_affinity_tag(int tag) {
    thread_affinity_policy_data_t policy = { tag };
    thread_policy_set(mach_thread_self(), THREAD_AFFINITY_POLICY,
                      (thread_policy_t)&policy, 1);
}

/* ------------------------------------------------------------------ */
/* Ping-pong measurement                                               */
/* ------------------------------------------------------------------ */
typedef struct {
    _Atomic int  flag __attribute__((aligned(128)));  /* on its own cache line */
    _Atomic int  done __attribute__((aligned(128)));
    long         count;
    int          core_tag;
    double       result_ns;
} pingpong_t;

static void *pong_thread(void *arg) {
    pingpong_t *pp = (pingpong_t *)arg;
    set_affinity_tag(pp->core_tag);

    while (!atomic_load_explicit(&pp->done, memory_order_relaxed)) {
        while (atomic_load_explicit(&pp->flag, memory_order_relaxed) == 0 &&
               !atomic_load_explicit(&pp->done, memory_order_relaxed)) { /* spin */ }
        if (atomic_load_explicit(&pp->done, memory_order_relaxed)) break;
        atomic_store_explicit(&pp->flag, 0, memory_order_relaxed);
    }
    return NULL;
}

static double measure_pingpong(int tag_a, int tag_b, long count) {
    pingpong_t *pp = aligned_alloc(128, sizeof(pingpong_t));
    memset(pp, 0, sizeof(pingpong_t));
    pp->count = count;
    pp->core_tag = tag_b;

    pthread_t tid;
    pthread_create(&tid, NULL, pong_thread, pp);

    set_affinity_tag(tag_a);

    /* Give threads time to get scheduled on different cores */
    usleep(10000);

    /* Warmup */
    for (int i = 0; i < 1000; i++) {
        atomic_store_explicit(&pp->flag, 1, memory_order_relaxed);
        while (atomic_load_explicit(&pp->flag, memory_order_relaxed) != 0) { /* spin */ }
    }

    /* Measure */
    uint64_t t0 = ticks();
    for (long i = 0; i < count; i++) {
        atomic_store_explicit(&pp->flag, 1, memory_order_relaxed);
        while (atomic_load_explicit(&pp->flag, memory_order_relaxed) != 0) { /* spin */ }
    }
    uint64_t t1 = ticks();

    atomic_store_explicit(&pp->done, 1, memory_order_relaxed);
    atomic_store_explicit(&pp->flag, 1, memory_order_relaxed);  /* wake pong if spinning */
    pthread_join(tid, NULL);

    double total_ns = (t1 - t0) * g_ticks_to_ns;
    double round_trip_ns = total_ns / (double)count;

    free(pp);
    return round_trip_ns;
}

int main(void) {
    init_timer();

    char brand[256] = "unknown";
    size_t len = sizeof(brand);
    sysctlbyname("machdep.cpu.brand_string", brand, &len, NULL, 0);

    int ncpu = get_sysctl_int("hw.ncpu");
    int pcores = 0, ecores = 0;
    int nperf = get_sysctl_int("hw.nperflevels");
    if (nperf >= 1) pcores = get_sysctl_int("hw.perflevel0.physicalcpu");
    if (nperf >= 2) ecores = get_sysctl_int("hw.perflevel1.physicalcpu");

    printf("========================================================\n");
    printf("  Inter-Core Latency Benchmark\n");
    printf("========================================================\n\n");
    printf("CPU:             %s\n", brand);
    printf("Cores:           %d P-cores, %d E-cores (%d logical)\n", pcores, ecores, ncpu);
    printf("\nMeasuring cache-line ping-pong round-trip latency...\n");
    printf("(Using thread affinity tags -- results are best-effort\n");
    printf(" as macOS affinity is advisory, not mandatory)\n\n");

    long count = 2000000;

    /*
     * Thread affinity on macOS: threads with the same tag prefer the same
     * core, threads with different tags get separated. We use distinct tags
     * to force separation.
     *
     * We measure with several different tag pairs:
     * - Small tag values (1, 2) tend to stay on P-cores (higher QoS default)
     * - We measure multiple pairs to capture the different pairings
     */

    printf("%-30s  %12s\n", "Core Pair", "Round-trip");
    printf("%-30s  %12s\n", "-----------------------------", "----------");

    /* Measure several tag pairs -- the OS will place them on different cores */
    struct {
        const char *label;
        int tag_a, tag_b;
    } tests[] = {
        { "Pair A (tags 1,2)",         1,  2 },
        { "Pair B (tags 3,4)",         3,  4 },
        { "Pair C (tags 5,6)",         5,  6 },
        { "Pair D (tags 1,100)",       1, 100 },
        { "Pair E (tags 50,200)",     50, 200 },
        { "Pair F (tags 1,1000)",      1, 1000 },
    };
    int ntests = sizeof(tests) / sizeof(tests[0]);

    double min_lat = 1e9, max_lat = 0;

    for (int i = 0; i < ntests; i++) {
        double ns = measure_pingpong(tests[i].tag_a, tests[i].tag_b, count);
        printf("  %-28s  %8.1f ns\n", tests[i].label, ns);
        if (ns < min_lat) min_lat = ns;
        if (ns > max_lat) max_lat = ns;
    }

    printf("\n--- Summary ---\n");
    printf("  Best (likely same cluster):     %8.1f ns\n", min_lat);
    printf("  Worst (likely cross-cluster):   %8.1f ns\n", max_lat);
    printf("  One-way estimate (best/2):      %8.1f ns\n", min_lat / 2.0);

    printf("\nNote: macOS does not expose direct core pinning. Tags are\n");
    printf("advisory hints. Results approximate real core-to-core latency.\n");

    printf("\n========================================================\n");
    return 0;
}
