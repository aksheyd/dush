# Contributing

Anyone can merge a change that keeps the gate green. The gate is what proves
`dush` still matches `/usr/bin/du`, so read this before you optimize anything.

## The merge gate

```sh
brew install zig just atf kyua coreutils hyperfine
curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain none
just test
just proof
```

`just test` and `just proof` are what CI runs on macOS. Both must pass with no
edits to the suites:

- `just checks`: no comments in our own code, Zig unit and parity
  tests, the frozen `du` totals suite, the freeze check and the README check.
- `just frozen`: the Zig ports of the BSD and GNU `du` suites (`tests/frozen/`).
- `just upstream`: the FreeBSD, Apple and GNU coreutils `du` scripts run
  verbatim (`tests/upstream/`).
- `just proof`: builds the Lean proofs in `proofs/` with warnings as errors,
  rejects `sorry` and custom axioms, audits the axioms of every main theorem,
  regenerates `proofs/vectors/golden.txt` and fails if it changed, then runs the
  bridge (`tests/proof/bridge_test.zig`), which checks `src/` against those
  vectors. elan installs the pinned toolchain from `proofs/lean-toolchain`.

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

The differential fuzzer (`tests/fuzz/`) joins the gate as soon as it lands. The
proofs and bridge cover `accounting.howmany`, `Scale`, `format.humanize`,
`inodes.linkStep` and `InodeSet.chargeFile`. Every file charge must go through
`InodeSet.chargeFile`. If you change one of those functions on purpose, change
the Lean model to match, rerun `just proof` and commit the regenerated vectors.
[proofs/README.md](proofs/README.md) lists what is proven, what is only tested
and what is not covered.

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

- No comments at all, full-line or trailing, in `.zig`, `.lean`, `.sh`, `.pl`,
  `.py`, workflow, `Makefile`, `justfile` or `.tape` files. Only the frozen
  verbatim suites in `tests/frozen/` and `tests/upstream/` are exempt.
  `just no-comments` enforces it; put explanations in a README.
- `dush` invoked as `du` must stay byte-for-byte `/usr/bin/du`. As `dush`, only
  the documented defaults (`-s`, `-h`, the `dush:` prefix, `--threads`) differ.
- Change `README.md` whenever `src/` changes; the README check enforces it.
