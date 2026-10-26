du_env := "env -u BLOCKSIZE -u BLOCK_SIZE -u DU_BLOCK_SIZE -u POSIXLY_CORRECT COMMAND_MODE=legacy LC_ALL=C"

test: checks frozen upstream

checks: no-comments zig-test du-suite freeze-check readme-check

frozen: frozen-bsd frozen-gnu

upstream: upstream-bsd upstream-gnu

no-comments:
    zig test tools/comments.zig
    zig run tools/comments.zig

zig-test:
    make test

du-suite:
    {{du_env}} zig test tests/frozen/suite.zig

du-link:
    make dush
    mkdir -p zig-out/du
    ln -sf ../../dush zig-out/du/du

frozen-bsd: du-link
    DUSH_BIN="$PWD/zig-out/du/du" zig test tests/frozen/bsd/du_test.zig

frozen-gnu:
    make dush
    mkdir -p zig-out/logs
    {{du_env}} DUSH_BIN="$PWD/dush" zig test tests/frozen/gnu/all.zig > zig-out/logs/frozen-gnu.log 2>&1 || true
    sh tools/zig_results.sh zig-out/logs/frozen-gnu.log > zig-out/logs/frozen-gnu.results
    sh tools/baseline.sh tests/frozen/gnu/EXPECTED zig-out/logs/frozen-gnu.results zig-out/logs/frozen-gnu.log

upstream-bsd:
    make dush
    DUSH_BIN="${DUSH_BIN:-$PWD/dush}" sh tools/upstream_bsd.sh

upstream-gnu:
    make dush
    DUSH_BIN="${DUSH_BIN:-$PWD/dush}" sh tools/upstream_gnu.sh

freeze-check:
    zig run tools/freeze.zig

readme-check:
    zig run tools/readme.zig -- check

bench-compare base="origin/main" *trees="":
    sh tools/bench_compare.sh {{base}} {{trees}}

record-bench:
    make bench
    zig run tools/readme.zig -- record

fuzz_run := "zig run -O ReleaseSafe -lc tests/fuzz/main.zig --"

fuzz SEEDS="1:1500":
    make dush
    {{fuzz_run}} run --target ./dush --seeds {{SEEDS}}

fuzz-long SECONDS="1800":
    make dush
    {{fuzz_run}} run --target ./dush --seconds {{SECONDS}} --random

fuzz-replay SEED:
    make dush
    {{fuzz_run}} replay --target ./dush --seed {{SEED}}

fuzz-selftest SEEDS="1:500":
    {{fuzz_run}} run --target /usr/bin/du --seeds {{SEEDS}} --failures fuzz-failures/selftest-du
    for m in order blocksize exit stderr k; do {{fuzz_run}} run --target tests/fuzz/broken_du.sh --target-env BROKEN_MODE=$m --seeds {{SEEDS}} --no-shrink --expect-mismatch --failures fuzz-failures/selftest-$m >/dev/null 2>&1 && echo "broken $m: caught" || { echo "broken $m: NOT caught"; exit 1; }; done

fuzz-stress *ARGS:
    make dush
    {{fuzz_run}} stress --target ./dush {{ARGS}}
