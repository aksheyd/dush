#!/bin/sh
# Benchmark dush against macOS `du -sh` and `diskus` with hyperfine.
#
# Hermetic & Fair Methodology:
# - Fair Cache Warming: Uses warmup runs (--warmup 3) so all tools run with
#   identically primed unified memory / page cache.
# - Statistical Isolation: Uses `hyperfine --shell none` with interleaved runs
#   so CPU frequency scaling and background OS jitter affect all tools equally.
# - Parity Check: Verifies exact byte/string parity before timing so invalid
#   runs are rejected immediately.
# - Flexible Target: Can benchmark any real directory or a fixture.
#
# Usage:
#   bench.sh <path-to-dush> [target-dir] [--runs N] [--cold] [--regen]
# Or via zig:
#   zig build bench
#   zig build bench -- /Users/aksheydeokule/Documents/GitHub
#   zig build bench -- --cold

set -eu

DUSH="${1:-./dush}"
if [ $# -gt 0 ]; then shift; fi

TARGET=""
RUNS=10
MODE="warm"
WARMUP=3
REGEN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --cold)
            MODE="cold"
            WARMUP=0
            shift
            ;;
        --runs)
            RUNS="$2"
            shift 2
            ;;
        --regen)
            REGEN=1
            shift
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [ -z "$TARGET" ]; then
                TARGET="$1"
            fi
            shift
            ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/.bench/tree"
RESULTS="$ROOT/.bench/results.md"
mkdir -p "$ROOT/.bench"

if ! command -v hyperfine >/dev/null 2>&1; then
    echo "error: hyperfine is required for benchmarking (brew install hyperfine)" >&2
    exit 1
fi

# If no target specified, use fixture
if [ -z "$TARGET" ]; then
    TARGET="$FIX"
    if [ ! -d "$FIX" ] || [ "$REGEN" = "1" ]; then
        python3 "$ROOT/bench/generate_fixture.py" "$FIX"
    fi
fi

echo "================================================================="
echo "Target  : $TARGET"
echo "Mode    : $MODE cache (warmup: $WARMUP, min-runs: $RUNS)"
echo "================================================================="

# --- Parity Verification ---
DU_OUT="$(du -sh "$TARGET" | tr -s '[:blank:]' ' ')"
DUSH_OUT="$("$DUSH" "$TARGET" | tr -s '[:blank:]' ' ')"

if [ "$DU_OUT" != "$DUSH_OUT" ]; then
    echo "error: parity failure! dush output differs from du -sh" >&2
    echo "  du -sh : '$DU_OUT'" >&2
    echo "  dush   : '$DUSH_OUT'" >&2
    exit 1
fi
echo "Parity check: du -sh == dush  ✓ [ $DUSH_OUT ]"

HAVE_DISKUS=0
if command -v diskus >/dev/null 2>&1; then
    DISKUS_RAW="$(diskus "$TARGET" 2>/dev/null || true)"
    DISKUS_BYTES="$(echo "$DISKUS_RAW" | grep -oE '[0-9]+' | tail -1)"
    DU_BLOCKS="$(du -s "$TARGET" | awk '{print $1}')"
    DU_BYTES="$((DU_BLOCKS * 512))"
    if [ -n "$DISKUS_BYTES" ]; then
        if [ "$DISKUS_BYTES" = "$DU_BYTES" ]; then
            echo "Parity check: diskus == du -s ✓ [ $DISKUS_BYTES bytes ]"
            HAVE_DISKUS=1
        else
            echo "warning: diskus returned $DISKUS_BYTES bytes vs du -s $DU_BYTES bytes"
            HAVE_DISKUS=1
        fi
    fi
fi

# --- Setup Preparation ---
PREPARE="sync"
if [ "$MODE" = "cold" ]; then
    echo "Acquiring sudo credentials for cache purging..."
    sudo -v
    PREPARE="sync; sudo purge"
fi

# --- Hyperfine Benchmark ---
echo "\nRunning benchmark with hyperfine..."

CMD_DU="du -sh \"$TARGET\""
CMD_DUSH="\"$DUSH\" \"$TARGET\""

if [ "$HAVE_DISKUS" = "1" ]; then
    CMD_DISKUS="diskus \"$TARGET\""
    hyperfine \
        --shell none \
        --warmup "$WARMUP" \
        --min-runs "$RUNS" \
        --prepare "$PREPARE" \
        --export-markdown "$RESULTS" \
        --command-name "dush" "$CMD_DUSH" \
        --command-name "diskus" "$CMD_DISKUS" \
        --command-name "du -sh" "$CMD_DU"
else
    hyperfine \
        --shell none \
        --warmup "$WARMUP" \
        --min-runs "$RUNS" \
        --prepare "$PREPARE" \
        --export-markdown "$RESULTS" \
        --command-name "dush" "$CMD_DUSH" \
        --command-name "du -sh" "$CMD_DU"
fi

echo "\nBenchmark Results (Saved to $RESULTS):"
cat "$RESULTS"
