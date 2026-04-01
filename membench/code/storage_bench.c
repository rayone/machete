/*
 * storage_bench.c - Storage I/O Benchmark
 *
 * Build: cc -O2 -pthread -o storage_bench storage_bench.c
 * Usage: ./storage_bench [test_file_path] [file_size_mb]
 *        Defaults: ./bench_testfile, 1024 MB
 *
 * NOTE: The test file is deleted after benchmarking.
 *
 * === METHODOLOGY ===
 *
 * SINGLE-THREADED (QD=1)
 *   Sequential read/write with 1 MB blocks, random 4K read/write IOPS,
 *   and fsync latency. All use F_NOCACHE to bypass the page cache.
 *   This measures worst-case throughput from userspace at queue depth 1.
 *
 * MULTI-THREADED RANDOM IOPS (QD>1)
 *   Spawns N threads each issuing independent pread()/pwrite() calls to
 *   random 4K offsets simultaneously. This simulates queue depth = N from
 *   the NVMe controller's perspective and reveals peak IOPS capability.
 *   Apple NVMe controllers support queue depths of 64+, so single-threaded
 *   IOPS (QD=1) is typically 50-70% below peak.
 *   Threads: 1, 4, 8, 16 (capped at hw.ncpu)
 *
 * OUTPUT FORMAT
 *   Fixed-width labels for easy diffing between machines.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/stat.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>

#define BLOCK_4K  4096
#define BLOCK_1M  (1024 * 1024)

static double g_ticks_to_ns;

static void init_timer(void) {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    g_ticks_to_ns = (double)info.numer / (double)info.denom;
}

static inline uint64_t ticks(void) { return mach_absolute_time(); }
static inline double ticks_to_sec(uint64_t t) { return t * g_ticks_to_ns / 1e9; }

static uint64_t xorshift64(uint64_t *state) {
    uint64_t x = *state;
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    *state = x;
    return x;
}

static int get_sysctl_int(const char *name) {
    int val = 0; size_t len = sizeof(val);
    sysctlbyname(name, &val, &len, NULL, 0);
    return val;
}

/* ------------------------------------------------------------------ */
/* Multi-threaded random I/O                                           */
/* ------------------------------------------------------------------ */
typedef struct {
    const char *filepath;
    long        file_size;
    long        num_ops;     /* ops per thread */
    int         is_write;
    uint64_t    rng_seed;
    double      elapsed_s;
} io_thread_arg_t;

static void *io_thread_func(void *arg) {
    io_thread_arg_t *a = (io_thread_arg_t *)arg;

    int flags = a->is_write ? O_RDWR : O_RDONLY;
    int fd = open(a->filepath, flags);
    if (fd < 0) { a->elapsed_s = -1; return NULL; }
    fcntl(fd, F_NOCACHE, 1);

    char *buf = aligned_alloc(4096, BLOCK_4K);
    if (a->is_write) memset(buf, 0xAB, BLOCK_4K);

    long num_4k_blocks = a->file_size / BLOCK_4K;
    uint64_t rng = a->rng_seed;

    uint64_t t0 = ticks();
    for (long i = 0; i < a->num_ops; i++) {
        off_t offset = (off_t)(xorshift64(&rng) % (uint64_t)num_4k_blocks) * BLOCK_4K;
        if (a->is_write)
            pwrite(fd, buf, BLOCK_4K, offset);
        else
            pread(fd, buf, BLOCK_4K, offset);
    }
    if (a->is_write) fsync(fd);
    uint64_t t1 = ticks();

    a->elapsed_s = ticks_to_sec(t1 - t0);
    free(buf);
    close(fd);
    return NULL;
}

static void run_mt_iops(const char *filepath, long file_size, int nthreads,
                        long ops_per_thread, int is_write)
{
    pthread_t *tids = calloc(nthreads, sizeof(pthread_t));
    io_thread_arg_t *args = calloc(nthreads, sizeof(io_thread_arg_t));

    for (int t = 0; t < nthreads; t++) {
        args[t].filepath  = filepath;
        args[t].file_size = file_size;
        args[t].num_ops   = ops_per_thread;
        args[t].is_write  = is_write;
        args[t].rng_seed  = (uint64_t)(t * 1234567 + 42);
        pthread_create(&tids[t], NULL, io_thread_func, &args[t]);
    }

    double max_elapsed = 0;
    int any_failed = 0;
    for (int t = 0; t < nthreads; t++) {
        pthread_join(tids[t], NULL);
        if (args[t].elapsed_s < 0) { any_failed = 1; continue; }
        if (args[t].elapsed_s > max_elapsed)
            max_elapsed = args[t].elapsed_s;
    }

    free(tids);
    free(args);

    if (any_failed || max_elapsed <= 0) {
        printf("  QD=%-2d %-5s  FAILED\n", nthreads, is_write ? "write" : "read");
        return;
    }

    long total_ops = (long)nthreads * ops_per_thread;
    double iops = total_ops / max_elapsed;
    double mbps = (iops * BLOCK_4K) / (1024.0 * 1024.0);

    printf("  QD=%-2d %-6s  %8.0f IOPS  (%6.0f MB/s)\n",
           nthreads, is_write ? "write:" : "read:", iops, mbps);
}

int main(int argc, char **argv) {
    init_timer();

    const char *filepath = "./bench_testfile";
    long file_mb = 1024;

    if (argc >= 2) filepath = argv[1];
    if (argc >= 3) file_mb = atol(argv[2]);
    if (file_mb < 64) file_mb = 64;

    long file_size    = file_mb * 1024L * 1024L;
    long num_1m_blocks = file_size / BLOCK_1M;
    long num_4k_blocks = file_size / BLOCK_4K;

    int ncpu = get_sysctl_int("hw.ncpu");
    if (ncpu <= 0) ncpu = 8;

    printf("========================================================\n");
    printf("  Storage I/O Benchmark\n");
    printf("========================================================\n\n");
    printf("Test file:       %s\n", filepath);
    printf("File size:       %ld MB\n", file_mb);
    printf("\n");

    char *buf = aligned_alloc(4096, BLOCK_1M);
    if (!buf) { perror("alloc"); return 1; }
    memset(buf, 'X', BLOCK_1M);

    /* ---- Sequential Write ---- */
    {
        int fd = open(filepath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) { perror("open"); return 1; }
        fcntl(fd, F_NOCACHE, 1);

        uint64_t t0 = ticks();
        for (long i = 0; i < num_1m_blocks; i++) {
            ssize_t w = write(fd, buf, BLOCK_1M);
            if (w != BLOCK_1M) { perror("write"); break; }
        }
        fsync(fd);
        uint64_t t1 = ticks();
        close(fd);

        double mbps = (double)file_mb / ticks_to_sec(t1 - t0);
        printf("Sequential Write (QD=1):   %8.0f MB/s  (%.2f GB/s)\n", mbps, mbps/1024.0);
    }

    /* ---- Sequential Read ---- */
    {
        int fd = open(filepath, O_RDONLY);
        if (fd < 0) { perror("open"); return 1; }
        fcntl(fd, F_NOCACHE, 1);

        uint64_t t0 = ticks();
        for (long i = 0; i < num_1m_blocks; i++) {
            ssize_t r = read(fd, buf, BLOCK_1M);
            if (r != BLOCK_1M) { perror("read"); break; }
        }
        uint64_t t1 = ticks();
        close(fd);

        double mbps = (double)file_mb / ticks_to_sec(t1 - t0);
        printf("Sequential Read  (QD=1):   %8.0f MB/s  (%.2f GB/s)\n", mbps, mbps/1024.0);
    }

    /* ---- Random Read (4K, QD=1) ---- */
    {
        int fd = open(filepath, O_RDONLY);
        if (fd < 0) { perror("open"); return 1; }
        fcntl(fd, F_NOCACHE, 1);

        char *buf4k = aligned_alloc(4096, BLOCK_4K);
        long num_ops = 50000;
        uint64_t rng = 42;

        uint64_t t0 = ticks();
        for (long i = 0; i < num_ops; i++) {
            off_t offset = (off_t)(xorshift64(&rng) % (uint64_t)num_4k_blocks) * BLOCK_4K;
            pread(fd, buf4k, BLOCK_4K, offset);
        }
        uint64_t t1 = ticks();
        close(fd);

        double iops = num_ops / ticks_to_sec(t1 - t0);
        double mbps = (iops * BLOCK_4K) / (1024.0 * 1024.0);
        printf("Random Read  4K  (QD=1):   %8.0f IOPS  (%6.0f MB/s)\n", iops, mbps);
        free(buf4k);
    }

    /* ---- Random Write (4K, QD=1) ---- */
    {
        int fd = open(filepath, O_RDWR);
        if (fd < 0) { perror("open"); return 1; }
        fcntl(fd, F_NOCACHE, 1);

        char *buf4k = aligned_alloc(4096, BLOCK_4K);
        memset(buf4k, 'R', BLOCK_4K);
        long num_ops = 50000;
        uint64_t rng = 99;

        uint64_t t0 = ticks();
        for (long i = 0; i < num_ops; i++) {
            off_t offset = (off_t)(xorshift64(&rng) % (uint64_t)num_4k_blocks) * BLOCK_4K;
            pwrite(fd, buf4k, BLOCK_4K, offset);
        }
        fsync(fd);
        uint64_t t1 = ticks();
        close(fd);

        double iops = num_ops / ticks_to_sec(t1 - t0);
        double mbps = (iops * BLOCK_4K) / (1024.0 * 1024.0);
        printf("Random Write 4K  (QD=1):   %8.0f IOPS  (%6.0f MB/s)\n", iops, mbps);
        free(buf4k);
    }

    /* ---- fsync Latency ---- */
    {
        int fd = open(filepath, O_RDWR);
        if (fd < 0) { perror("open"); return 1; }

        char one = 'Z';
        int n = 1000;
        uint64_t t0 = ticks();
        for (int i = 0; i < n; i++) {
            pwrite(fd, &one, 1, 0);
            fsync(fd);
        }
        uint64_t t1 = ticks();
        close(fd);

        double avg_us = (ticks_to_sec(t1 - t0) / n) * 1e6;
        printf("fsync Latency:             %8.1f us avg\n", avg_us);
    }

    /* ---- Multi-threaded Random IOPS ---- */
    printf("\n--- Multi-threaded Random 4K IOPS (simulated queue depth) ---\n");
    printf("  (Each thread issues independent pread/pwrite calls concurrently)\n\n");

    /* Ops per thread: enough for ~3s of I/O at expected QD=1 rates */
    long ops_per_thread = 15000;

    int qd_levels[] = { 1, 4, 8, 16, 0 };
    for (int i = 0; qd_levels[i] != 0; i++) {
        int qd = qd_levels[i];
        if (qd > ncpu) break;
        run_mt_iops(filepath, file_size, qd, ops_per_thread, 0 /* read */);
    }
    printf("\n");
    for (int i = 0; qd_levels[i] != 0; i++) {
        int qd = qd_levels[i];
        if (qd > ncpu) break;
        run_mt_iops(filepath, file_size, qd, ops_per_thread, 1 /* write */);
    }

    /* Cleanup */
    unlink(filepath);
    free(buf);

    printf("\n========================================================\n");
    return 0;
}
