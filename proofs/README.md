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
| `Dush/Units.lean` | Per-entry charge, 512-byte rounding, `-k`/`-m`/`-g` and `BLOCKSIZE` conversion |
| `Dush/Humanize.lean` | The `du -h` formatter (`humanize_number` with dush's arguments) |
| `Dush/Accounting.lean` | Hard-link dedup, traversal-order independence, N parallel workers |
| `Dush/Operands.lean` | Several operands, `-c`, and macOS `du`'s expiring `linkchk` table |
| `Audit.lean` | Axiom audit of the main theorems |
| `Ref.lean` | `dushref`, which writes `vectors/golden.txt` |

## What is proven

All of these are theorems over natural numbers, checked by Lean's kernel.

### (a) Order and worker-split independence (`Dush/Accounting.lean`)

The model mirrors the kernel that every file site in `src/walk.zig` calls,
`InodeSet.chargeFile` in `src/inodes.zig`: an entry is skipped when `nlink > 1` and
`seen(dev, ino)` is true, and is otherwise charged its byte weight. `seen` ignores inode 0 and
never forgets a key. Every theorem holds for any per-entry weight `w`, so it covers both
physical and `-A` charging.

- `total_perm`: two traversals that are permutations of each other give the same total, provided
  the snapshot is *consistent*, meaning two sightings of the same `(dev, ino)` agree on
  `nlink > 1` and on size. `order_matters_without_consistency` shows that this assumption is
  needed.
- `workers_sum` and `parallel_eq_sequential`: tag each entry with the worker (< N) that
  processed it, in the order the mutex-protected inode set handled the calls. Each worker sums
  its own charges (`local_bytes`) and adds them to the shared total once (`fetchAdd`). The sum
  of the N partial sums equals one sequential pass over the trace, and therefore equals the
  sequential total of the traversal in any order.

### (b) Each hard-linked inode is counted exactly once

- `counted_once`: if any entry with `nlink > 1` and key `k` (inode not 0) appears, exactly one
  entry with key `k` is charged.
- `counted_untracked`: every entry with `nlink ≤ 1` or inode 0 is charged.
- `counted_sublist`: the charged entries are a subsequence of the traversal.
- `total_eq_counted`: the total is the sum of the weights of the charged entries.

### (c) Rounding and block conversion (`Dush/Units.lean`)

- `roundUp512_dvd`, `le_roundUp512`, `roundUp512_least`: `roundUp512 n` is the least multiple of
  512 that is ≥ `n`.
- `entryBytes_eq_duUnits`: dush's per-entry bytes are exactly 512 × du's per-entry units
  (`st_blocks`, or `howmany(st_size, 512)` with `-A`).
- `dushBlocks_eq_du_apparent` and `dushBlocks_eq_du_physical`: dush's `(bytes + bs - 1) / bs`
  equals du's `howmany` formula. With `-A` this holds for every block size. Without `-A` it
  needs a block size that is a multiple of 512.
- `flag_blocks_agree`: the block sizes for `-k`, `-m`, and `-g` are multiples of 512, so dush and
  du agree on them.
- `getbsize_bounds` and `getbsize_suffix_dvd`: a model of `getbsize(3)`. Any `K`, `M`, or `G`
  suffix yields a multiple of 512.
- `blocksize_1000_quirk` and `blocksize_1000_apparent`: with `BLOCKSIZE=1000`, du prints 16 for
  a 16-block file (verified on macOS), not 9. dush does not read `BLOCKSIZE`.

### (d) `du -h` (`Dush/Humanize.lean`)

`humanize` is a literal transcription of `humanize_number(buf, 5, n, "", HN_AUTOSCALE,
HN_B | HN_NOSPACE | HN_DECIMAL)` for `n ≥ 0`. This is what du's `prthumanval` calls, and the
same loop as `format.humanize`.

- `humanize_eq_closed`: the loop equals a loop-free formula.
- `scale_eq_iff`: the unit-selection rule. Unit `s` (B, K, M, G, T, P, E) is chosen exactly when
  `thr (s-1) ≤ n < thr s`, where `thr 0 = 1000` and `thr (s+1) = 1023488 · 1024^s`. Here
  1023488 = 999.5 × 1024, the point where 999.5K rounds up to 1.0M.
- `mantissa_eq`: the printed mantissa is `n / 1024^(s-1)` before the final rounding.
- `scale_mono` and `value10_mono`: monotonicity. A larger size never gets a smaller unit or a
  smaller displayed value.
- `value10_upper` and `value10_lower`: each unit displays values from 1.0 to 999.
- `mantissa_bounds`: for every `i64` total, the string fits du's 4-character column.
- Exact strings checked by the kernel, including `0B`, `999B`, `1.0K` for 1000, `9.9K` for
  10188, `10K` for 10189, `999K` for 1023487, `1.0M` for 1023488, and `1.0G`.

### (e) `-c` and inodes shared across operands (`Dush/Operands.lean`)

- `grand_total_eq`: dush shares one inode set across operands and prints the sum of the operand
  totals. That `total` line equals one pass over all operands' entries, so with consistency it
  does not depend on operand order. The split between the per-operand lines does depend on
  order: a file shared by two operands is charged to whichever comes first.
- `du_grand_total_eq`: the same statement for du, whose `-c` total is the sum of root operand
  totals.
- `du_eq_dush`: du's `linkchk` remembers a hard-linked inode for only `nlink` sightings.
  Within one run, if no inode with `nlink > 1` is met more often than its link count and those
  inodes have nonzero inode numbers, du's expiring table and dush's permanent set give the same
  total. `dush_bytes_eq_du_units` restates this in du's 512-byte units.
- `du_expiry_counterexample`: when the condition fails, they disagree. `du -c a a a` with `a` a
  2-link, 16-block file prints `16`, `16`, `32 total` on macOS, because the table entry expires
  after two sightings. dush charges the inode once.
- `total_line_not_sum_of_lines`: with `-k`, the `total` line is rounded once, so it can be
  smaller than the sum of the rounded per-operand lines. du does the same.

## What is only tested against the proof

These links between the model and `src/` are checked by tests, not proven:

- `tests/proof/bridge_test.zig` reads `vectors/golden.txt`, about 8,800 vectors produced by the
  Lean definitions above, and checks:
  - `format.humanize` on every boundary in every unit, on powers of two ±1, on 4,000
    pseudo-random values, and on `2^63 - 1`;
  - `accounting.roundUp512`, `accounting.statBytes` (physical and `-A`), and
    `accounting.toBlocks` for block sizes 512, 1000, 1024, 4096, 1M, and 1G;
  - 400 traces of hard-linked, unlinked, and inode-0 entries split across 3 operands. Each trace
    runs through the real `InodeSet.chargeFile`, sequentially per operand, compared with
    `opTotals` and the `-c` total. It then runs again with 1, 2, 4, and 8 threads sharing one
    `InodeSet` and an atomic total, compared with the Lean total.
- That the Lean `humanize` and the unit model agree with macOS `/usr/bin/du`. This is not
  proven, because the model transcribes `humanize_number` rather than deriving it from libc. It
  was checked once on macOS:
  - `du -A -h` on sparse files gave the golden string for all 144 golden vectors that are
    multiples of 512 and that APFS could create (up to 2^54 bytes);
  - the `BLOCKSIZE` and `du -c a a a` cases above were also checked.

  The parity, frozen, and upstream suites in `tests/` cover this more broadly. None of these
  checks is part of `just proof`.
- That the Zig `i64` arithmetic matches the Lean natural-number arithmetic. The vectors stay
  below `2^63`, and the bridge exercises values near that limit. Overflow is not proven absent.

## What is NOT covered

- **Syscalls.** That `fstatat`, `getattrlistbulk`, and `openat` return what the model assumes is
  not proven. In particular, the model assumes that a hard-linked inode reports the same
  `nlink` and size at every sighting. It also assumes that the bulk path's
  `ATTR_FILE_ALLOCSIZE` equals `st_blocks * 512`, which can differ, for example on compressed
  files.
- **The `getattrlistbulk` walk.** It is not proven that `src/walk.zig` visits each directory
  entry exactly once. The model starts from whatever list of entries the walk reaches. Also not
  proven:
  - directory dedup and subtree skipping (the per-operand `dirs` set);
  - `-x`, `-L`/`-H`/`-P`, and symlink handling;
  - error paths and partial results;
  - `InodeSet.seen` returning `false` when its allocation fails.
- **The concurrency memory model.** The theorems assume that `InodeSet`'s mutex makes `seen`
  linearizable, and that every worker's `fetchAdd` completes before `scanTarget` reads the total
  (the threads are joined first). The Zig and C11 memory models are not formalized. The bridge
  runs real threads, but a passing run is evidence, not proof.
- **Output lines.** Tab separation, `%4s` padding, path printing, `-d` depth limits, and
  `-a`/`-s` selection are not modeled.
- **Known differences from du that the model records but does not fix:**
  - dush ignores `BLOCKSIZE`.
  - dush never forgets a hard link, while du forgets one after `nlink` sightings. They differ
    only when an inode is met more often than its link count, for example when the same file is
    passed twice.
  - When a hard-linked non-directory operand was already charged, dush prints a `0` line for it,
    while du prints nothing. The `-c` total is unaffected.
