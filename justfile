test: no-comments zig-test du-suite freeze-check readme-check

no-comments:
    zig run check/comments.zig

zig-test:
    make test

du-suite:
    zig test frozen/suite.zig

freeze-check:
    zig run frozen/freeze.zig

readme-check:
    zig run bench/readme.zig -- check

record-bench:
    make bench
    zig run bench/readme.zig -- record
