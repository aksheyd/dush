# Differential fuzzer and stress harness

Black-box tests that run `dush` next to `/usr/bin/du` and compare what they print. Nothing here imports `src/`. The harness only executes binaries.

## What a case is

Each case comes from one seed (`gen.zig`), and the same seed always gives the same case. A case has three parts:

- **A tree.** It can contain:
  - nested and empty directories
  - files of 0, 1, 511, 512, 513, 4095 and 4096 bytes, plus random sizes and 1–4 MiB files
  - sparse files up to 5 GiB
  - hard links within and across directories, including to symlinks
  - symlinks: relative, absolute, dangling, self-loops, loop pairs, chains, `.` and `..`
  - directories with modes 000, 300, 600, 500, 100, 200 and 400, and unreadable files
  - `UF_NODUMP` flags (macOS)
  - long names, names in NFC and NFD Unicode, CJK and emoji, and names with spaces, dashes, globs, newlines and quotes
  - chains of directories deeper than `PATH_MAX`
- **Arguments.** Random combinations of `-a -A -B N -c -d N -g -H -h -I pat -k -L -l -m -n -P -r -s -t N -x --si`, bundled (`-sh`) or split (`-d 1`). Operands can be `.`, directories, files, symlinks, missing paths or `""`, written with trailing `/` or `//`, a `./` prefix, absolute paths or duplicates. Occasionally there is a `--`, or a flag after the operands.
- **An environment.** `BLOCKSIZE` (valid and invalid values), `COMMAND_MODE` (`legacy`, `unix2003` or junk), `POSIXLY_CORRECT`, or `LC_ALL=en_US.UTF-8`. The base environment is `PATH=/usr/bin:/bin LC_ALL=C`.

`dush` is executed through a symlink named `du`. That is the mode that has to match `du` exactly.

## What counts as a mismatch

These are compared byte for byte:

- stdout
- the exit code
- stderr

The only normalization is the program name: a leading `dush: ` and the invocation path both become `du`. A hang (10 s by default) or a death by signal is always a mismatch. If the reference itself times out, the case is skipped and counted. When a case mismatches, `/usr/bin/du` runs a second time; if its own result changes, the rerun becomes the reference, the case is counted as reference unstable, and `case.txt` says so. macOS `du` does this on its first look at some freshly made symlink loops: seed 12634 prints `0` for `-P -s a.c43/c49/e63/` once and `Too many levels of symbolic links` on every later run. When stdout differs only in line order, the case is labelled `order` so it is easy to find, but it still counts as a mismatch.

## Shrinking and repros

The first `--per-bucket` cases for each kind of difference get shrunk. The shrinker drops env vars, argument groups and chunks of the tree, and then zeroes file sizes. A shrunk case is kept only if it still produces the same kind of difference.

Each shrunk case is written to `fuzz-failures/<bucket>/seed-N/` as two files:

- `case.txt`: the seed, the arguments, the env, the tree ops and both outputs
- `repro.sh`: a standalone script that rebuilds the tree in a temp dir, runs both commands and prints a diff. Run it with `DUSH=./dush sh repro.sh`. It exits 0 when they match.

`fuzz-failures/summary.txt` counts every mismatch by difference and flags, and lists the minimized buckets. Old repros are not deleted between runs, so remove `fuzz-failures/` yourself when you want a clean slate.

## Recipes

```
just fuzz                   seeds 1:1500, fixed, used by CI
just fuzz-long 1800         random seeds for 30 minutes
just fuzz-replay 1234       rebuild seed 1234, print it, write its repro
just fuzz-selftest          /usr/bin/du against itself (must be clean) and against broken_du.sh (must be caught)
just fuzz-stress            thread-count determinism, du-mode stability, concurrent mutation
```

The driver can also be run directly: `zig run -O ReleaseSafe -lc tests/fuzz/main.zig -- run --target ./dush --seeds 1:200`. Options:

| Option | Effect |
| --- | --- |
| `--jobs N` | parallel workers (default: half the CPUs) |
| `--seconds N --random` | time-boxed run with fresh seeds |
| `--seed-base N` | reproduce a random run |
| `--timeout S` | per-command hang limit |
| `--target-env K=V` | extra env for the target only |
| `--no-shrink` | skip shrinking |
| `--expect-mismatch` | exit 0 only when something is caught |

`broken_du.sh` wraps `du` and breaks it in one way, chosen with `BROKEN_MODE`:

| `BROKEN_MODE` | What it breaks |
| --- | --- |
| `order` | reverses the output lines |
| `blocksize` | drops `BLOCKSIZE` |
| `exit` | always exits 0 |
| `stderr` | discards stderr |
| `k` | forces `-k` |

The selftest only passes when the harness catches each mode.

## Stress

`stress` builds one large deterministic tree: 3000 directories and 40,000 entries with hard links, symlinks and a few unreadable directories. It then runs three phases:

1. **Thread determinism.** Runs `dush` with every thread count from 1 to 2×CPUs, `--iterations` times each, with no flags and with `-A`, `-c` and `-L`. Each run must match the 1-thread result exactly.
2. **du-mode stability.** Runs the `du` symlink repeatedly with `-s`, `-a`, `-d 2`, `-c -k`, `-A -s`, `-L -s` and `-l -s`. It fails if the runs differ from each other, and it also reports how many differ from `/usr/bin/du`.
3. **Concurrent mutation.** A thread creates, writes, renames, links and removes entries in a subtree while `dush` and the `du` symlink run. Each run must finish without a hang or a signal, exit 0 or 1, and end its output with a newline.

The thread flag defaults to `--threads={}`. Use `--thread-arg '-t{}'` for builds that still take `-t N`. Other stress options:

- `--threads-max`
- `--iterations`
- `--files`
- `--dirs`
- `--du-runs`
- `--mutate-runs`
- `--tree-seed`

## Safety

- Trees are built under `$TMPDIR/dush-fuzz-<pid>`, or under `--work`.
- Symlinks never point outside the case root, except for the fixed dangling `/nonexistent-dush-fuzz`.
- `chmod` never follows a symlink.
- Permissions are restored with `chmod -R u+rwx` before every delete.
