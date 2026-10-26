test: checks frozen upstream

checks: no-comments zig-test du-suite freeze-check readme-check

frozen: frozen-bsd frozen-gnu

upstream: upstream-bsd upstream-gnu

no-comments:
    zig run tools/comments.zig

zig-test:
    make test

du-suite:
    zig test tests/frozen/suite.zig

frozen-bsd:
    make dush
    DUSH_BIN="$PWD/dush" zig test tests/frozen/bsd/du_test.zig

frozen-gnu:
    make dush
    DUSH_BIN="$PWD/dush" zig test tests/frozen/gnu/all.zig

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
