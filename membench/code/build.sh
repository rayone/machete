#!/bin/bash
#
# build.sh - Compile the macOS benchmark suite
#
# Usage:  ./build.sh [--force]
#
# Options:
#   --force   Recompile all binaries even if already up to date
#   --help    Show this help
#
# Binaries are placed in ./build/ and can be copied to any Apple Silicon
# Mac running a compatible macOS version — no recompilation needed there.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
FORCE=0

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
skip()  { echo -e "${BOLD}[SKIP]${RESET}  $*"; }

# ---- Parse arguments ----
for arg in "$@"; do
    case "$arg" in
        --force)    FORCE=1 ;;
        --help|-h)
            head -17 "$0" | tail -14
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Run with --help for usage."
            exit 1
            ;;
    esac
done

# ---- Check prerequisites ----
if ! command -v cc &>/dev/null; then
    fail "cc not found. Install Xcode Command Line Tools: xcode-select --install"
    exit 1
fi

mkdir -p "$BUILD_DIR"

# ---- Helper: compile if source is newer than binary (or --force) ----
compile_c() {
    local src="$1" out="$2"
    shift 2
    local src_path="$SCRIPT_DIR/$src"
    local out_path="$BUILD_DIR/$out"

    if [ $FORCE -eq 0 ] && [ -f "$out_path" ] && [ "$out_path" -nt "$src_path" ]; then
        skip "$out (up to date)"
        return 0
    fi

    if cc -O2 -pthread -o "$out_path" "$src_path" "$@" 2>&1; then
        ok "Built $out"
    else
        fail "Failed to build $out"
        return 1
    fi
}

compile_objc() {
    local src="$1" out="$2"
    shift 2
    local src_path="$SCRIPT_DIR/$src"
    local out_path="$BUILD_DIR/$out"

    if [ $FORCE -eq 0 ] && [ -f "$out_path" ] && [ "$out_path" -nt "$src_path" ]; then
        skip "$out (up to date)"
        return 0
    fi

    if clang -O2 -o "$out_path" "$src_path" "$@" 2>&1; then
        ok "Built $out"
    else
        fail "Failed to build $out (needs Metal framework — skipping)"
        return 1
    fi
}

# ---- Compile all benchmarks ----
info "Compiling benchmarks into $BUILD_DIR ..."
echo ""

compile_c   sysinfo.c        sysinfo        -framework IOKit -framework CoreFoundation
compile_c   cpu_membench.c   cpu_membench
compile_c   cpu_compute.c    cpu_compute    -lm
compile_c   cache_bench.c    cache_bench
compile_c   intercore_bench.c intercore_bench
compile_c   storage_bench.c  storage_bench
compile_objc gpu_membench.m  gpu_membench   -framework Metal -framework Foundation

echo ""
ok "Build complete. Binaries are in $BUILD_DIR"
info "Copy the build/ directory to any Apple Silicon Mac and run ./run.sh"
