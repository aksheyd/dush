test: checks frozen upstream

checks: no-comments zig-test du-suite freeze-check readme-check

frozen: frozen-bsd frozen-gnu

upstream: upstream-bsd upstream-gnu

no-comments:
    zig run check/comments.zig

zig-test:
    make test

du-suite:
    zig test frozen/suite.zig

frozen-bsd:
    make dush
    DUSH_BIN="$PWD/dush" zig test frozen/bsd/du_test.zig

frozen-gnu:
    make dush
    DUSH_BIN="$PWD/dush" zig test frozen/gnu/all.zig

upstream-bsd:
    make dush
    DUSH_BIN="${DUSH_BIN:-$PWD/dush}" sh check/upstream_bsd.sh

upstream-gnu:
    make dush
    DUSH_BIN="${DUSH_BIN:-$PWD/dush}" sh check/upstream_gnu.sh

freeze-check:
    zig run frozen/freeze.zig

readme-check:
    zig run bench/readme.zig -- check

record-bench:
    make bench
    zig run bench/readme.zig -- record
