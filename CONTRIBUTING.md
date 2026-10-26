# Contributing

Anyone can merge a change that keeps the gate green. The gate is what proves
`dush` still matches `/usr/bin/du`, so read this before you optimize anything.

## The merge gate

```sh
brew install zig just atf kyua coreutils hyperfine
just test
```

`just test` is what CI runs on macOS. It must pass with no edits to the suites:

- `just checks`: no comments in our own code, Zig unit and parity
  tests, the frozen `du` totals suite, the freeze check and the README check.
- `just frozen`: the Zig ports of the BSD and GNU `du` suites (`tests/frozen/`).
- `just upstream`: the FreeBSD, Apple and GNU coreutils `du` scripts run
  verbatim (`tests/upstream/`).

Some upstream and GNU-port cases fail or skip for `/usr/bin/du` itself (GNU-only
options, UFS-specific sizes, Linux-only setups). Each suite's `EXPECTED` file
lists those outcomes with a reason, and the run fails on any deviation in either
direction: a new failure, an unexpected pass, or a test that changed skip state
or stopped running. If an outcome changes on purpose, confirm `/usr/bin/du` gets
the same outcome (run the suite with `DUSH_BIN=/usr/bin/du`) and update the
`EXPECTED` line with a reason in the same PR.

## Frozen files

Existing files under `tests/frozen/` and `tests/upstream/` are immutable. The
freeze check fails a PR that edits one; a commit message containing
`ALLOW-FROZEN-EDIT` overrides it and needs the owner's sign-off. Adding new files
there (such as an `EXPECTED` baseline) is allowed.

## Fuzzing and proofs

The differential fuzzer (`tests/fuzz/`) and the Lean proofs of the size math
(`proofs/`) join the gate as soon as they land; when they do, run their `just`
recipes alongside `just test`. The proofs cover `accounting.howmany`, `Scale` and
`inodes.linkStep`; if you change those functions, the proofs must still check.

## Performance changes

Compare your branch with `main` on real trees before you merge:

```sh
just bench-compare                      # origin/main vs HEAD on .bench/tree
just bench-compare origin/main ~/big ~/small
```

It builds both in ReleaseFast and runs `hyperfine --warmup 3 --shell none` in
alternating rounds (`BENCH_ROUNDS`, `BENCH_RUNS`), then prints each tree's
median round mean and the head/base ratio. Run it on an idle machine. The
README table is common-case only; refresh it with `just record-bench`.

## Style

- No comments at all, full-line or trailing, in `.zig`, `.sh`, `.pl`, `.py`,
  workflow, `Makefile`, `justfile` or `.tape` files. Only the frozen verbatim
  suites in `tests/frozen/` and `tests/upstream/` are exempt.
- `dush` invoked as `du` must stay byte-for-byte `/usr/bin/du`. As `dush`, only
  the documented defaults (`-s`, `-h`, the `dush:` prefix, `--threads`) differ.
- Change `README.md` whenever `src/` changes; the README check enforces it.
