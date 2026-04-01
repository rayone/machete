#!/bin/bash
#
# run.sh - Run the macOS benchmark suite using pre-built binaries
#
# Usage:  ./run.sh [options]
#
# Options:
#   --all           Run all benchmarks (default)
#   --cpu-mem       CPU memory bandwidth & latency
#   --gpu-mem       GPU memory bandwidth (Metal)
#   --cpu-compute   CPU compute throughput (FLOPS)
#   --storage       Storage I/O
#   --cache         Cache hierarchy sweep
#   --intercore     Inter-core latency
#   --sysinfo       System hardware info only (no benchmarks)
#   --help          Show this help
#
# Requires binaries to be present in ./build/
# Run ./build.sh first (once), then copy build/ to any Apple Silicon Mac.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"

# Colors (if terminal supports them)
if [ -t 1 ]; then
    BOLD="\033[1m"
    GREEN="\033[32m"
    YELLOW="\033[33m"
    RED="\033[31m"
    CYAN="\033[36m"
    RESET="\033[0m"
else
    BOLD="" GREEN="" YELLOW="" RED="" CYAN="" RESET=""
fi

info()  { echo -e "${BOLD}${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${BOLD}${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${BOLD}${YELLOW}[WARN]${RESET}  $*"; }
fail()  { echo -e "${BOLD}${RED}[FAIL]${RESET}  $*"; }

# ---- Parse arguments ----
RUN_CPU_MEM=0
RUN_GPU_MEM=0
RUN_CPU_COMPUTE=0
RUN_STORAGE=0
RUN_CACHE=0
RUN_INTERCORE=0
RUN_SYSINFO_ONLY=0
RUN_ALL=1

if [ $# -gt 0 ]; then
    RUN_ALL=0
    for arg in "$@"; do
        case "$arg" in
            --all)          RUN_ALL=1 ;;
            --cpu-mem)      RUN_CPU_MEM=1 ;;
            --gpu-mem)      RUN_GPU_MEM=1 ;;
            --cpu-compute)  RUN_CPU_COMPUTE=1 ;;
            --storage)      RUN_STORAGE=1 ;;
            --cache)        RUN_CACHE=1 ;;
            --intercore)    RUN_INTERCORE=1 ;;
            --sysinfo)      RUN_SYSINFO_ONLY=1 ;;
            --help|-h)
                head -20 "$0" | tail -17
                exit 0
                ;;
            *)
                echo "Unknown option: $arg"
                echo "Run with --help for usage."
                exit 1
                ;;
        esac
    done
fi

if [ $RUN_ALL -eq 1 ]; then
    RUN_CPU_MEM=1
    RUN_GPU_MEM=1
    RUN_CPU_COMPUTE=1
    RUN_STORAGE=1
    RUN_CACHE=1
    RUN_INTERCORE=1
fi

# ---- Check that binaries exist ----
if [ ! -d "$BUILD_DIR" ] || [ ! -f "$BUILD_DIR/sysinfo" ]; then
    fail "Binaries not found in $BUILD_DIR"
    fail "Run ./build.sh first to compile the benchmarks."
    exit 1
fi

# ---- Run ----
echo ""
echo "========================================================"
echo "  macOS System Benchmark Suite"
echo "  $(date)"
echo "========================================================"

# Always print system info first
echo ""
"$BUILD_DIR/sysinfo"

if [ $RUN_SYSINFO_ONLY -eq 1 ]; then
    exit 0
fi

if [ $RUN_CPU_MEM -eq 1 ]; then
    echo ""
    "$BUILD_DIR/cpu_membench"
fi

if [ $RUN_GPU_MEM -eq 1 ]; then
    if [ -f "$BUILD_DIR/gpu_membench" ]; then
        echo ""
        "$BUILD_DIR/gpu_membench"
    else
        warn "gpu_membench binary not found in $BUILD_DIR — skipping"
    fi
fi

if [ $RUN_CPU_COMPUTE -eq 1 ]; then
    echo ""
    "$BUILD_DIR/cpu_compute"
fi

if [ $RUN_CACHE -eq 1 ]; then
    echo ""
    "$BUILD_DIR/cache_bench"
fi

if [ $RUN_INTERCORE -eq 1 ]; then
    echo ""
    "$BUILD_DIR/intercore_bench"
fi

if [ $RUN_STORAGE -eq 1 ]; then
    echo ""
    info "Storage benchmark writes a 1 GB temp file. This may take a moment..."
    echo ""
    "$BUILD_DIR/storage_bench" "$BUILD_DIR/bench_testfile" 1024
fi

echo ""
echo "========================================================"
echo "  All benchmarks complete."
echo "========================================================"
