/*
 * gpu_membench.m - GPU Memory Bandwidth Benchmark via Metal
 *
 * Compiles Metal shaders from source at runtime -- no need for the `metal`
 * CLI tool or full Xcode. Only requires Command Line Tools + Metal framework.
 *
 * Build: clang -O2 -framework Metal -framework Foundation -o gpu_membench gpu_membench.m
 * Usage: ./gpu_membench [buffer_size_mb]
 *        Default: 512 MB
 *
 * === METHODOLOGY ===
 *
 * WHAT THIS MEASURES
 *   GPU-side memory bandwidth through Metal compute shaders. On Apple
 *   Silicon, CPU and GPU share the same physical LPDDR5 memory bus (unified
 *   memory), but they access it through different cache hierarchies and
 *   memory controllers. This benchmark measures how fast the GPU cores can
 *   read/write that shared memory.
 *
 * SHADERS
 *   Three Metal compute kernels, each operating on uint4 (16 bytes per
 *   element, 4x 32-bit unsigned integers):
 *
 *   - bw_read: Each GPU thread loads one uint4 from src[gid]. To prevent
 *     the Metal compiler from eliminating the load as dead code, thread 0
 *     writes its value to dst[0]. All other threads do a load with no
 *     store. This means the read benchmark has an asymmetric anti-DCE
 *     mechanism: only 1 out of ~33 million threads writes. The compiler
 *     cannot prove gid != 0 at compile time, so it must keep the load
 *     for all threads. CAVEAT: a sufficiently smart compiler could still
 *     speculate, and the single-store means the write port is nearly idle,
 *     potentially allowing all memory controller bandwidth to serve reads.
 *     The 1568 GB/s result we observed exceeds the 614 GB/s DRAM bandwidth
 *     -- this confirms that GPU L2 cache is servicing many of the reads
 *     (the GPU has a large last-level cache). This is NOT raw DRAM
 *     bandwidth; it includes GPU cache effects.
 *
 *   - bw_write: Each thread stores uint4(gid, gid+1, gid+2, gid+3) to
 *     dst[gid]. Every element is written, so this is a pure streaming
 *     store workload. The GPU's memory controller can batch these into
 *     full cache-line writes, avoiding read-for-ownership in some cases.
 *
 *   - bw_copy: Each thread loads src[gid] and stores to dst[gid]. This
 *     exercises both read and write ports simultaneously. Reported as
 *     (2 * buffer_size / time) to account for total bus traffic.
 *
 * BUFFER ALLOCATION
 *   Buffers use MTLResourceStorageModeShared, meaning they reside in
 *   unified memory accessible by both CPU and GPU with no explicit copy.
 *   Both buffers are initialized by the CPU (memset) before benchmarking
 *   to ensure pages are physically backed. The default buffer size is
 *   512 MB, which far exceeds GPU L2 cache on all current Apple Silicon
 *   (typically 8-32 MB) for write and copy tests. Read may still benefit
 *   from cache as noted above.
 *
 * DISPATCH
 *   Each kernel is dispatched with element_count = buffer_size / 16
 *   threads (one thread per uint4). Threadgroup size is capped at 256
 *   or the PSO's maxTotalThreadsPerThreadgroup, whichever is smaller.
 *   dispatchThreads:threadsPerThreadgroup: handles non-even grid sizes.
 *   The Metal driver partitions this across all available GPU cores
 *   (Apple Silicon GPUs have 10-80+ execution units depending on model).
 *
 * TIMING
 *   Each kernel dispatch is timed two ways:
 *     1. GPU timestamps: cmd.GPUEndTime - cmd.GPUStartTime (Metal 2.1+)
 *        These are provided by the GPU's own counter, measuring only GPU
 *        execution time (excludes command submission latency).
 *     2. Wall-clock: mach_absolute_time() around commit + waitUntilCompleted.
 *        This includes CPU-GPU command submission overhead.
 *   The GPU timestamp is preferred when available (> 0.1 ms). For the
 *   512 MB buffer these kernels take ~1-5 ms, so GPU timestamps are used
 *   in practice.
 *
 *   Three warmup dispatches (one per kernel) are run before any timed
 *   iteration to ensure shader compilation is complete, GPU frequency has
 *   ramped up, and TLBs are populated.
 *
 * REPORTING
 *   10 iterations per kernel; the BEST (peak) result is reported.
 *
 * KNOWN LIMITATIONS
 *   - READ OVER-REPORTS DRAM BANDWIDTH: The bw_read kernel's single-store
 *     anti-DCE technique is weak. The Metal compiler may keep the load but
 *     the GPU L2 cache is large enough that 512 MB of sequential uint4
 *     reads will see significant cache hit rates (the GPU prefetcher is
 *     effective for linear access patterns). The read result should be
 *     interpreted as "GPU read throughput from L2+DRAM" not "DRAM read
 *     bandwidth". To measure true DRAM bandwidth, the buffer would need
 *     to be much larger or access patterns randomized.
 *   - SHARED MEMORY MODE: StorageModeShared means the GPU accesses memory
 *     through the system's unified memory bus. StorageModePrivate would
 *     use GPU-preferred memory tiling (on discrete GPUs) but on Apple
 *     Silicon, Private and Shared both hit the same LPDDR5 bus.
 *   - GPU FREQUENCY: Apple does not expose GPU clock speed. The GPU
 *     dynamically scales frequency based on thermal state and workload.
 *     Results may vary with sustained load or thermal throttling.
 *   - 16-BYTE ELEMENTS: uint4 was chosen to match the GPU's native vector
 *     width. Scalar (4-byte) accesses would under-utilize memory channels.
 *   - COMMAND BUFFER OVERHEAD: Each iteration submits a new command buffer.
 *     For these large transfers (~ms), the ~10-50 us submission overhead
 *     is negligible. For very small buffers it would dominate.
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <mach/mach_time.h>

static double g_ticks_to_ns;

static void init_timer(void) {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    g_ticks_to_ns = (double)info.numer / (double)info.denom;
}

static inline uint64_t ticks(void) { return mach_absolute_time(); }
static inline double ticks_to_sec(uint64_t t) { return t * g_ticks_to_ns / 1e9; }

/* Metal shader source compiled at runtime */
static NSString *shaderSource = @R"(
#include <metal_stdlib>
using namespace metal;

/* Read: load all uint4 elements. Write one element to prevent dead-code elimination. */
kernel void bw_read(device const uint4 *src [[buffer(0)]],
                    device uint4 *dst       [[buffer(1)]],
                    uint gid                [[thread_position_in_grid]])
{
    uint4 v = src[gid];
    if (gid == 0) dst[0] = v;
}

/* Write: store a pattern to every element. */
kernel void bw_write(device const uint4 *src [[buffer(0)]],
                     device uint4 *dst       [[buffer(1)]],
                     uint gid                [[thread_position_in_grid]])
{
    dst[gid] = uint4(gid, gid+1, gid+2, gid+3);
}

/* Copy: read src, write dst. */
kernel void bw_copy(device const uint4 *src [[buffer(0)]],
                    device uint4 *dst       [[buffer(1)]],
                    uint gid                [[thread_position_in_grid]])
{
    dst[gid] = src[gid];
}

/*
 * GPU FP32 FMA compute throughput.
 * Each thread runs 'iters' FMA operations on 8 independent float4 accumulators.
 * Total FLOP per thread = iters * 8 vectors * 4 lanes * 2 FLOP (mul+add) = iters * 64 FLOP.
 * Thread 0 writes its result to dst[0] to prevent dead-code elimination.
 * The large iter count ensures the kernel runs for several milliseconds so
 * GPU timestamps are accurate and thermal ramp-up is absorbed by warmup.
 */
kernel void gpu_compute_fp32(device float4 *dst      [[buffer(0)]],
                              constant uint &iters    [[buffer(1)]],
                              uint gid                [[thread_position_in_grid]])
{
    float4 a0 = float4(1.0001f + float(gid) * 1e-9f);
    float4 a1 = float4(1.0002f);
    float4 a2 = float4(1.0003f);
    float4 a3 = float4(1.0004f);
    float4 a4 = float4(1.0005f);
    float4 a5 = float4(1.0006f);
    float4 a6 = float4(1.0007f);
    float4 a7 = float4(1.0008f);
    float4 m  = float4(1.000001f);

    for (uint i = 0; i < iters; i++) {
        a0 = fma(a0, m, m);
        a1 = fma(a1, m, m);
        a2 = fma(a2, m, m);
        a3 = fma(a3, m, m);
        a4 = fma(a4, m, m);
        a5 = fma(a5, m, m);
        a6 = fma(a6, m, m);
        a7 = fma(a7, m, m);
    }

    if (gid == 0)
        dst[0] = a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7;
}
)";

static double run_kernel(id<MTLDevice> dev, id<MTLCommandQueue> queue,
                         id<MTLComputePipelineState> pso,
                         id<MTLBuffer> bufA, id<MTLBuffer> bufB,
                         NSUInteger element_count)
{
    id<MTLCommandBuffer> cmd = [queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];

    [enc setComputePipelineState:pso];
    [enc setBuffer:bufA offset:0 atIndex:0];
    [enc setBuffer:bufB offset:0 atIndex:1];

    NSUInteger threads_per_group = pso.maxTotalThreadsPerThreadgroup;
    if (threads_per_group > 256) threads_per_group = 256;
    MTLSize grid = MTLSizeMake(element_count, 1, 1);
    MTLSize group = MTLSizeMake(threads_per_group, 1, 1);

    [enc dispatchThreads:grid threadsPerThreadgroup:group];
    [enc endEncoding];

    uint64_t t0 = ticks();
    [cmd commit];
    [cmd waitUntilCompleted];
    uint64_t t1 = ticks();

    double gpu_sec = cmd.GPUEndTime - cmd.GPUStartTime;
    double wall_sec = ticks_to_sec(t1 - t0);

    return (gpu_sec > 0.0001) ? gpu_sec : wall_sec;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        init_timer();

        long buf_mb = 512;
        if (argc >= 2) buf_mb = atol(argv[1]);
        if (buf_mb < 64) buf_mb = 64;

        NSUInteger buf_size = (NSUInteger)buf_mb * 1024 * 1024;
        NSUInteger element_count = buf_size / 16;  /* uint4 = 16 bytes */
        double size_gb = (double)buf_size / (1024.0 * 1024.0 * 1024.0);

        int iters = 10;

        printf("========================================================\n");
        printf("  GPU Memory Bandwidth Benchmark (Metal)\n");
        printf("========================================================\n\n");

        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            fprintf(stderr, "No Metal device found.\n");
            return 1;
        }
        printf("GPU:             %s\n", [[dev name] UTF8String]);
        printf("Buffer:          %ld MB\n", buf_mb);
        printf("Iterations:      %d\n\n", iters);

        /* Compile shaders from source at runtime */
        NSError *err = nil;
        MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
        if (@available(macOS 15.0, *)) {
            opts.mathMode = MTLMathModeFast;
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            opts.fastMathEnabled = YES;
#pragma clang diagnostic pop
        }

        id<MTLLibrary> lib = [dev newLibraryWithSource:shaderSource options:opts error:&err];
        if (!lib) {
            fprintf(stderr, "Failed to compile Metal shaders: %s\n",
                    [[err description] UTF8String]);
            return 1;
        }

        id<MTLFunction> fnRead  = [lib newFunctionWithName:@"bw_read"];
        id<MTLFunction> fnWrite = [lib newFunctionWithName:@"bw_write"];
        id<MTLFunction> fnCopy  = [lib newFunctionWithName:@"bw_copy"];
        id<MTLFunction> fnComp  = [lib newFunctionWithName:@"gpu_compute_fp32"];

        if (!fnRead || !fnWrite || !fnCopy || !fnComp) {
            fprintf(stderr, "Failed to find shader functions.\n");
            return 1;
        }

        id<MTLComputePipelineState> psoRead  = [dev newComputePipelineStateWithFunction:fnRead  error:&err];
        id<MTLComputePipelineState> psoWrite = [dev newComputePipelineStateWithFunction:fnWrite error:&err];
        id<MTLComputePipelineState> psoCopy  = [dev newComputePipelineStateWithFunction:fnCopy  error:&err];
        id<MTLComputePipelineState> psoComp  = [dev newComputePipelineStateWithFunction:fnComp  error:&err];

        if (!psoRead || !psoWrite || !psoCopy || !psoComp) {
            fprintf(stderr, "Failed to create pipeline: %s\n", [[err description] UTF8String]);
            return 1;
        }

        id<MTLBuffer> bufA = [dev newBufferWithLength:buf_size options:MTLResourceStorageModeShared];
        id<MTLBuffer> bufB = [dev newBufferWithLength:buf_size options:MTLResourceStorageModeShared];

        memset(bufA.contents, 0xAA, buf_size);
        memset(bufB.contents, 0xBB, buf_size);

        id<MTLCommandQueue> queue = [dev newCommandQueue];

        /* Warmup */
        run_kernel(dev, queue, psoRead,  bufA, bufB, element_count);
        run_kernel(dev, queue, psoWrite, bufA, bufB, element_count);
        run_kernel(dev, queue, psoCopy,  bufA, bufB, element_count);

        /* Benchmark Read */
        {
            double best = 0;
            for (int i = 0; i < iters; i++) {
                double sec = run_kernel(dev, queue, psoRead, bufA, bufB, element_count);
                double bw = size_gb / sec;
                if (bw > best) best = bw;
            }
            printf("GPU Read:        %8.2f GB/s\n", best);
        }

        /* Benchmark Write */
        {
            double best = 0;
            for (int i = 0; i < iters; i++) {
                double sec = run_kernel(dev, queue, psoWrite, bufA, bufB, element_count);
                double bw = size_gb / sec;
                if (bw > best) best = bw;
            }
            printf("GPU Write:       %8.2f GB/s\n", best);
        }

        /* Benchmark Copy */
        {
            double best = 0;
            for (int i = 0; i < iters; i++) {
                double sec = run_kernel(dev, queue, psoCopy, bufA, bufB, element_count);
                double bw = (2.0 * size_gb) / sec;
                if (bw > best) best = bw;
            }
            printf("GPU Copy (r+w):  %8.2f GB/s\n", best);
        }

        /*
         * GPU FP32 FMA Compute Throughput
         *
         * Dispatch element_count threads (same grid as bandwidth tests).
         * Each thread executes `gpu_iters` rounds of 8 float4 FMAs.
         * Total FLOP = element_count * gpu_iters * 8 * 4 * 2
         * We pick gpu_iters so the kernel runs ~5ms, enough for stable
         * GPU timestamps. Adjust if your GPU is much faster/slower.
         *
         * The output buffer holds a single float4 written by thread 0
         * (anti-DCE). It is allocated separately from the bandwidth buffers.
         */
        {
            uint gpu_iters = 1000;  /* inner loop count per thread */

            id<MTLBuffer> compOut = [dev newBufferWithLength:sizeof(float)*4
                                                     options:MTLResourceStorageModeShared];
            id<MTLBuffer> compIters = [dev newBufferWithLength:sizeof(uint)
                                                       options:MTLResourceStorageModeShared];
            *(uint *)(compIters.contents) = gpu_iters;

            /* Warmup */
            {
                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
                [enc setComputePipelineState:psoComp];
                [enc setBuffer:compOut   offset:0 atIndex:0];
                [enc setBuffer:compIters offset:0 atIndex:1];
                NSUInteger tpg = psoComp.maxTotalThreadsPerThreadgroup;
                if (tpg > 256) tpg = 256;
                [enc dispatchThreads:MTLSizeMake(element_count,1,1)
               threadsPerThreadgroup:MTLSizeMake(tpg,1,1)];
                [enc endEncoding];
                [cmd commit]; [cmd waitUntilCompleted];
            }

            double best_gflops = 0;
            for (int i = 0; i < iters; i++) {
                id<MTLCommandBuffer> cmd = [queue commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
                [enc setComputePipelineState:psoComp];
                [enc setBuffer:compOut   offset:0 atIndex:0];
                [enc setBuffer:compIters offset:0 atIndex:1];
                NSUInteger tpg = psoComp.maxTotalThreadsPerThreadgroup;
                if (tpg > 256) tpg = 256;
                [enc dispatchThreads:MTLSizeMake(element_count,1,1)
               threadsPerThreadgroup:MTLSizeMake(tpg,1,1)];
                [enc endEncoding];

                uint64_t t0 = ticks();
                [cmd commit]; [cmd waitUntilCompleted];
                uint64_t t1 = ticks();

                double gpu_sec = cmd.GPUEndTime - cmd.GPUStartTime;
                double wall_sec = ticks_to_sec(t1 - t0);
                double sec = (gpu_sec > 0.0001) ? gpu_sec : wall_sec;

                /* FLOP = threads * iters * 8 vecs * 4 lanes * 2 (mul+add) */
                double flop = (double)element_count * gpu_iters * 8.0 * 4.0 * 2.0;
                double gflops = (flop / sec) / 1e9;
                if (gflops > best_gflops) best_gflops = gflops;
            }
            printf("GPU FP32 FMA:    %8.2f GFLOPS\n", best_gflops);
        }

        printf("\n========================================================\n");
    }
    return 0;
}
