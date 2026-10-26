du_env := "env -u BLOCKSIZE -u BLOCK_SIZE -u DU_BLOCK_SIZE -u POSIXLY_CORRECT COMMAND_MODE=legacy LC_ALL=C" # the env the frozen harnesses give /usr/bin/du, so dush sees the same

test: checks frozen upstream

checks: no-comments zig-test du-suite freeze-check readme-check

frozen: frozen-bsd frozen-gnu

upstream: upstream-bsd upstream-gnu

no-comments:
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

record-bench:
    make bench
    zig run tools/readme.zig -- record
