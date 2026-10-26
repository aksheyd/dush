#!/bin/sh
set -eu
base=${1:-origin/main}
shift 2>/dev/null || true
rounds=${BENCH_ROUNDS:-4}
runs=${BENCH_RUNS:-20}
root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/zig-out/bench-compare"
command -v hyperfine >/dev/null 2>&1 || { echo "bench-compare: needs hyperfine (brew install hyperfine)" >&2; exit 1; }
if [ $# -eq 0 ]; then
    test -d "$root/.bench/tree" || { echo "bench-compare: no tree given and no .bench/tree; run make bench once or pass directories" >&2; exit 1; }
    set -- "$root/.bench/tree"
fi
mkdir -p "$out"
wt=$(mktemp -d "${TMPDIR:-/tmp}/dush-bench-base.XXXXXX")
trap 'git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1 || true' EXIT
git -C "$root" worktree add --detach --force "$wt" "$base" >/dev/null 2>&1
(cd "$wt" && zig build -Doptimize=ReleaseFast >/dev/null)
cp "$wt/zig-out/bin/dush" "$out/dush-base"
(cd "$root" && zig build -Doptimize=ReleaseFast >/dev/null)
cp "$root/zig-out/bin/dush" "$out/dush-head"
echo "base: $base ($(git -C "$root" rev-parse --short "$base"))  head: $(git -C "$root" rev-parse --short HEAD)$(git -C "$root" diff --quiet HEAD -- src build.zig || echo '+dirty')"
for tree in "$@"; do
    : > "$out/means.tsv"
    r=1
    while [ $r -le "$rounds" ]; do
        if [ $((r % 2)) -eq 1 ]; then first=base; second=head; else first=head; second=base; fi
        hyperfine --warmup 3 --shell none --runs "$runs" --export-csv "$out/round.csv" \
            --command-name "$first" "$out/dush-$first $tree" \
            --command-name "$second" "$out/dush-$second $tree" >/dev/null
        awk -F, 'NR > 1 { print $1 "\t" $2 }' "$out/round.csv" >> "$out/means.tsv"
        r=$((r + 1))
    done
    awk -F '\t' -v tree="$tree" '
        function median(arr, n,    i, j, t) {
            for (i = 2; i <= n; i++) for (j = i; j > 1 && arr[j - 1] > arr[j]; j--) { t = arr[j]; arr[j] = arr[j - 1]; arr[j - 1] = t }
            return n % 2 ? arr[(n + 1) / 2] : (arr[n / 2] + arr[n / 2 + 1]) / 2
        }
        $1 == "base" { b[++nb] = $2 }
        $1 == "head" { h[++nh] = $2 }
        END {
            mb = median(b, nb); mh = median(h, nh)
            printf "%s: base %.1f ms, head %.1f ms (median of %d round means), head/base %.3f\n", tree, mb * 1000, mh * 1000, nb, mh / mb
        }' "$out/means.tsv"
done
