test: no-comments zig-test du-suite frozen-bsd freeze-check readme-check

no-comments:
    zig run check/comments.zig

zig-test:
    make test

du-suite:
    zig test frozen/suite.zig

frozen-bsd:
    make dush
    DUSH_BIN="$PWD/dush" zig test frozen/bsd/du_test.zig

freeze-check:
    zig run frozen/freeze.zig

readme-check:
    zig run bench/readme.zig -- check

record-bench:
    make bench
    zig run bench/readme.zig -- record

frozen-gnu:
    zig test frozen/gnu/all.zig
