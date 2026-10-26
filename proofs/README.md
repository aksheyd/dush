# Formal model of dush's size accounting

This directory holds a Lean 4 model of the arithmetic behind dush's output, with machine-checked
proofs. It uses only Lean core: no Mathlib, no `sorry`, no `native_decide`, and no custom axioms.
The toolchain is pinned in `lean-toolchain` (Lean v4.35.0).

The goal is that anyone can rewrite the hot paths, then run `just proof` and `just checks` to
confirm that the accounting still matches the proven model and macOS `du`.

```
just proof
```

`just proof` does the following:

1. Builds every proof with warnings as errors (`lake build --wfail`).
2. Rejects `sorry`, `admit`, `axiom`, `native_decide`, `implemented_by`, and `extern` anywhere in
   the model.
3. Runs `Audit.lean`. It prints the axioms behind each main theorem and fails unless they are a
   subset of Lean's standard `propext`, `Classical.choice`, and `Quot.sound`.
4. Regenerates `vectors/golden.txt` with the `dushref` executable and fails if the file changed.
5. Runs `zig build proof-bridge` (`tests/proof/bridge_test.zig`), which checks the functions in
   `src/` against those vectors. `zig build test` and `just checks` run the bridge too.

## Layout

| File | Contents |
| --- | --- |
| `Dush/Units.lean` | `howmany`, 512-byte rounding, `getbsize`, and `Scale` (du's `cblocksize`/`blocksize` arithmetic) |
| `Dush/Humanize.lean` | The `du -h` formatter (`humanize_number` with du's arguments) |
| `Dush/Accounting.lean` | The ideal hard-link model: a permanent seen-set, order and worker independence, exactly-once |
| `Dush/Operands.lean` | du's expiring `linkchk` table as `src/` implements it (`linkStep`, `duStep`), `-c`, and the link to the ideal model |
| `Audit.lean` | Axiom audit of the main theorems |
| `Ref.lean` | `dushref`, which writes `vectors/golden.txt` |

The Lean sources carry no comments, following the repository rule; this file is their
documentation. `just no-comments` (`tools/comments.zig`) rejects `--` and `/-` outside string
literals in every `.lean` file.

## The model

An entry is a sighting of a file: `(dev, ino, nlink, blocks, size)`. It is *tracked* when
`nlink > 1` and `ino ≠ 0`. Every non-directory charge site in `src/` (`walk.zig`'s bulk path,
its POSIX fallback and `scanTarget`, and `fts_walk.zig` unless `-l`) goes through
`InodeSet.chargeFile` in `src/inodes.zig`. That calls `visit`, which applies `linkStep`, the
transcription of macOS `du`'s `linkchk`: on the first sighting of a tracked inode it stores
`nlink - 1` remaining sightings and charges the entry; each later sighting decrements the count
and is skipped; at 0 the entry is dead and the next sighting charges again.

- `linkStep` in Lean is the same function over `Int` as the Zig one. `linkStep_eq_duStep` shows
  it agrees with `duStep`, the per-entry step used in the theorems.
- `duStep`/`duTotal` model `src/` and du. `step`/`total` in `Accounting.lean` model an ideal
  permanent seen-set, used as the reference for "each inode is counted once".
- Every theorem holds for any per-entry weight `w`, so it covers physical and `-A` charging and
  any `Scale`.

## What is proven

All of these are theorems over natural numbers, checked by Lean's kernel.

### (a) Order and worker-split independence

*Consistent* means two sightings of the same `(dev, ino)` agree on `nlink` and on weight.

- `duStep_comm`, `duTotal_perm`: two traversals that are permutations of each other give the
  same `duTotal`, provided the snapshot is consistent. `total_perm` is the same for the ideal
  model, and `order_matters_without_consistency` shows that the assumption is needed.
- `du_workers_sum`, `du_parallel_eq_sequential`: tag each entry with the worker (< N) that
  processed it, in the order the mutex-protected `InodeSet` handled the calls. Each worker sums
  its own charges and adds them to the shared total once (`fetchAdd`). The sum of the N partial
  sums equals one sequential pass over that trace, and therefore equals the sequential total of
  any traversal order. `workers_sum` and `parallel_eq_sequential` are the ideal-model versions.

### (b) Each hard-linked inode is counted exactly once

- `counted_once`, `counted_untracked`, `counted_sublist`, `total_eq_counted`: in the ideal
  model, every untracked entry is charged and exactly one sighting of each tracked inode is.
- `du_eq_dush`: if no tracked inode is seen more often than its link count (`LinkBounded`),
  `duTotal` equals the ideal `total`.
- `du_counted_once`: under the same condition, `src/`'s expiring table charges exactly one
  sighting of each tracked inode that appears.
- `du_expiry_counterexample`: without the condition, the expiring table charges an inode again.
  `du -c a a a` with `a` a 2-link, 16-block file prints `16`, `16` and `32 total` on macOS (the
  second sighting is skipped and prints no line), and `src/` does the same. The ideal set would
  charge `16, 0, 0`.

### (c) Rounding and block conversion (`Dush/Units.lean`)

- `roundUp512_dvd`, `le_roundUp512`, `roundUp512_least`: `roundUp512 n` is the least multiple of
  512 that is ≥ `n`.
- `entryBytes_eq_duUnits`, `dushBlocks_eq_howmany`, `dushBlocks_eq_du_apparent`,
  `dushBlocks_eq_du_physical`, `flag_blocks_agree`: byte-level rounding agrees with du's
  `howmany` units; with `-A` for every block size, otherwise for multiples of 512, which
  includes `-k`, `-m` and `-g`.
- `getbsize_bounds`, `getbsize_suffix_dvd`: a model of `getbsize(3)`'s clamping and suffixes.
- `scale_default_entry`, `scale_default_display`, `scale_default_human`, `scale_default_bytes`:
  with the default 512-byte `cblocksize`, `Scale.entryBlocks`, `display` and `humanBytes` equal
  du's units, `howmany` block conversion and `512 ×` units.
- `scale_physical_cb`: without `-A`, `Scale.init` rounds `cblocksize` up to whole sectors.
- `blocksize_1000_quirk`, `blocksize_1000_apparent`: with `BLOCKSIZE=1000`, du prints 16 for a
  16-block file (verified on macOS), not 9; `Scale` reproduces it.
- `dush_bytes_eq_du_units`: for any trace, the expiring-table total in bytes is exactly
  `512 ×` the total in du's units.

### (d) `du -h` (`Dush/Humanize.lean`)

`humanize` is a literal transcription of `humanize_number(buf, 5, n, "", HN_AUTOSCALE,
HN_B | HN_NOSPACE | HN_DECIMAL)` for `n ≥ 0`, which is what du's `prthumanval` calls.

- `humanize_eq_closed`: the loop equals a loop-free formula.
- `scale_eq_iff`: unit `s` (B, K, M, G, T, P, E) is chosen exactly when
  `thr (s-1) ≤ n < thr s`, where `thr 0 = 1000` and `thr (s+1) = 1023488 · 1024^s`
  (1023488 = 999.5 × 1024, where 999.5K rounds to 1.0M).
- `mantissa_eq`, `scale_mono`, `value10_mono`, `value10_upper`, `value10_lower`,
  `mantissa_bounds`: the mantissa formula, monotonicity, the 1.0 to 999 display range, and that
  every `i64` total fits du's 4-character column.
- Exact strings checked by the kernel: `0B`, `999B`, `1.0K` for 1000, `9.9K` for 10188, `10K`
  for 10189, `999K` for 1023487, `1.0M` for 1023488, and `1.0G`.

### (e) The `-c` total (`Dush/Operands.lean`)

- `du_grand_total_eq`: operands share one table, and the `-c` total, the sum of the per-operand
  totals, equals one pass over all operands' entries. With consistency it therefore does not
  depend on operand order (`duTotal_perm`). The split between per-operand lines does depend on
  order. `grand_total_eq` is the ideal-model version.
- `total_line_not_sum_of_lines`: with `-k` the `total` line is rounded once, so it can be
  smaller than the sum of the rounded per-operand lines. du does the same.

## What is only tested against the proof

These links between the model and `src/` are checked by tests, not proven:

- `tests/proof/bridge_test.zig` reads `vectors/golden.txt` (about 9,600 vectors produced by the
  Lean definitions) and checks:
  - `format.humanize` with `.binary` on every unit boundary, powers of two ±1, 4,000
    pseudo-random values and `2^63 - 1`;
  - `accounting.roundUp512`, `statBytes` (physical and `-A`) and `toBlocks`;
  - `accounting.Scale.init`, `entryBlocks`, `display` and `humanBytes` for raw `cblocksize`
    1 to 1M and raw `blocksize` 512 to 1G, physical and `-A`;
  - `inodes.linkStep` on every combination of `live`, `links` from -2 to 5 and `nlink` from -1
    to 6;
  - 400 traces of hard-linked, unlinked and inode-0 entries across 3 operands, run through the
    real `InodeSet.chargeFile` per operand and compared with `duOpTotals` and the `-c` total,
    once in bytes and once in `Scale` units (bytes = 512 × units), then again with 1, 2, 4 and
    8 threads sharing one `InodeSet` and an atomic total.
- That the Lean `humanize` and `Scale` agree with macOS `/usr/bin/du`. The model transcribes
  `humanize_number` and du.c rather than deriving them from libc. It was spot-checked on macOS,
  and the parity, frozen and upstream suites in `tests/` cover it more broadly; those are not
  part of `just proof`.
- That the Zig `i64` arithmetic matches the Lean natural-number arithmetic. The vectors stay
  below `2^63`; overflow is not proven absent.

## What is NOT covered

- **Syscalls and libc.** That `fstatat`, `getattrlistbulk`, `openat` and fts return what the
  model assumes, including the same `nlink` and size at every sighting of an inode and
  `ATTR_FILE_ALLOCSIZE == st_blocks * 512` on the bulk path. `src/` calls libc `getbsize`; only
  the Lean model of it is proven, and the bridge feeds `Scale.init` raw values.
- **`format.humanize` with `.si`** (`-H`/`--si`) is neither proven nor bridged.
- **`Scale.threshold`, `Scale.passes` and `fastPathCompatible`** (`-t`) are not modeled.
- **The walk.** That `walk.zig` and `fts_walk.zig` visit each entry exactly once, directory
  dedup (`dirs`), `-x`, `-L`/`-H`/`-P`, `-l` (which bypasses `chargeFile`), symlinks, error
  paths and allocation failure inside `InodeSet`.
- **The concurrency memory model.** The theorems assume `InodeSet`'s mutex makes `visit`
  linearizable and that every `fetchAdd` completes before the total is read. The bridge runs
  real threads, but a passing run is evidence, not proof.
- **Output lines.** Tabs, padding, paths, `-d`, `-a`/`-s` selection and which lines print.
