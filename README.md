# dush

A fast, drop-in replacement for `du -sh` on macOS.

<p align="center">
  <img src="assets/demo.gif" alt="dush terminal demo" width="800" />
</p>

## Why?

`dush` (pronounced like "douche") is a macOS `du -sh` replacement.

macOS `du -sh` is notoriously slow on large trees because POSIX traversal issues an individual `lstat`/`fstatat` syscall for every single file.

`dush` matches `du -sh` output byte-for-byte, but runs **3.73x faster than `du -sh`** and **2.02x faster than [`diskus`](https://github.com/sharkdp/diskus)**:

| Command | Mean | Min … Max | vs `dush` | Output Format |
| :--- | :---: | :---: | :---: | :--- |
| **`dush`** | **118.8 ms** | 115.2 … 130.0 ms | **1.00x** | `11G    /path` |
| `dush --threads=10` | 147.5 ms | 143.8 … 151.1 ms | 1.24x | `11G    /path` |
| `diskus` | 239.5 ms | 229.0 … 272.7 ms | 2.02x | `11419648000` |
| `du -sh` | 443.0 ms | 438.7 … 452.7 ms | 3.73x | `11G    /path` |

*Measured with `hyperfine --shell none --warmup 3` on an Apple M4 (4 performance cores), 164,000 files, 18,001 directories, 11G, warm cache. The default worker count is those 4 cores. `dush --threads=10` uses every logical core.*

GNU coreutils 9.12 (`gdu -sh`) took 457.0 ms (453.2 … 466.9 ms) on that same tree. On the small bench fixture (16,410 files, 667 directories, 4.8M) dush took 8.0 ms, diskus 16.5 ms, and `du -sh` 23.3 ms.

### How it works

- **`getattrlistbulk(2)` batching** — Reads names, file types, physical allocation sizes, and inode numbers in 64 KB kernel chunks in a single syscall. `fstatat` runs only when that call omits the size. Apparent size (`-A`) reads each entry's data length from the same call.
- **Work-stealing concurrency** — Traverses directory trees with thread-local stacks and byte accumulators. On Apple Silicon the default is the performance-core count; `--threads=N` (or `-j N`, or `DUSH_THREADS`) sets the worker count explicitly.
- **Zero-allocation traversal** — Processes file metadata directly in-place from the kernel bulk buffer without heap-allocating path strings.
- **Hardlink deduplication** — Accurately tracks multi-link inodes (`st_nlink > 1`) so hardlinks are counted exactly once.
- **`du`-style errors** — Entries that cannot be read are reported on stderr in the same format as `du`, left out of the size, and the walk continues; the total still prints and the exit status is 1.

## Installation

Requires [Zig](https://ziglang.org) 0.16 (`brew install zig`).

```sh
git clone https://github.com/aksheyd/dush.git
cd dush
make
sudo make install   # Installs to /usr/local/bin
```

Add an alias to your `~/.zshrc` or `~/.bashrc`:

```sh
alias du="dush"
```

## Usage

```sh
dush [FLAGS] [PATH ...]
```

If no path is specified, `dush` defaults to `.`.

```sh
$ dush
252K	.

$ dush -c src bench tests
 40K	src
 16K	bench
8.0K	tests
 64K	total
```

### `dush` vs `du`

`dush` accepts every macOS `du` flag, and each one means what it means to `du(1)` (`-t` is `du`'s size threshold, not a thread count). Only two defaults differ:

| | `dush` | `du` (a symlink or copy of `dush` named `du`) |
| :--- | :--- | :--- |
| Listing | `-s` unless `-a`, `-d` or `-s` is given | every directory, like `/usr/bin/du` |
| Units | `-h` unless `-k`, `-m`, `-g`, `--si` or `-B` is given | 512-byte blocks, or `BLOCKSIZE` |
| Error prefix | `dush:` | `du:` |
| Threads | `--threads=N`, `-j N` | `DUSH_THREADS` only, so the flag set is exactly `du`'s |

Run as `du`, it is a drop-in for `/usr/bin/du`: the same output bytes, messages, exit codes, `BLOCKSIZE` handling and `COMMAND_MODE` behavior. Install it as `du` with `ln -s "$(command -v dush)" ~/bin/du` (any directory ahead of `/usr/bin` in `PATH`).

### Flags

| Flag | Description |
| :--- | :--- |
| `-s` | Print only a total for each operand (default for `dush`) |
| `-h`, `--si` | Human-readable sizes, base 1024 (default for `dush`) or 1000 |
| `-a` | Print every file, not just directories |
| `-d depth` | Print directories at most `depth` levels down |
| `-c` | Display a grand total row at the end |
| `-A` | Apparent size (file length) rather than physical disk usage |
| `-k`, `-m`, `-g`, `-B size` | Block size units (1 KiB, 1 MiB, 1 GiB, or `size` bytes) |
| `-P` | Do not follow symlinks (default) |
| `-H` | Follow symlinks specified on the command line |
| `-L` | Follow all symlinks encountered during traversal |
| `-I mask` | Skip entries whose name matches the `fnmatch(3)` mask |
| `-l` | Count a hard-linked file once per link |
| `-n` | Skip files and directories with the `nodump` flag |
| `-t size` | Print only entries of at least `size` (below `-size` if negative) |
| `-x` | Stay on each operand's file system |
| `-r` | Accepted and ignored, as in `du` |
| `--threads=N`, `-j N` | Worker threads (`dush` only) |
| `-b`, `--apparent-size`, `--total`, `--summarize`, `--human-readable` | Aliases for `-A`, `-c`, `-s`, `-h` (`dush` only) |

## Verification

`dush` is tested against BSD `du -sh` for 100% numerical and formatting parity:

```sh
just test   # Same checks as CI: comment ban, Zig tests, frozen du suite, freeze check, README check, ported BSD and GNU du suites, upstream du suites, all against their EXPECTED baselines
make bench  # Runs hermetic hyperfine benchmark suite (uses native Zig generator)
```

`tests/upstream/` holds the FreeBSD, Apple and GNU coreutils `du` test scripts copied verbatim. `just upstream-bsd` runs the ATF scripts under kyua and `just upstream-gnu` runs the coreutils scripts with their own harness, both with `du` resolving to `dush`; see [tests/upstream/README.md](tests/upstream/README.md).

Not every upstream case passes against `/usr/bin/du` itself: GNU tests use GNU-only options, and a few FreeBSD tests assume UFS/ZFS sizes. Each suite has an `EXPECTED` file listing the outcomes `/usr/bin/du` gets, with a reason per non-pass. A suite passes when `dush` gets exactly those outcomes, so a new failure and an unexpected pass both fail CI; skips are counted and checked too. To check a baseline itself, run the suite with `DUSH_BIN=/usr/bin/du`. See [CONTRIBUTING.md](CONTRIBUTING.md) for the merge gate and `just bench-compare`.

`proofs/` holds a Lean 4 model of the size accounting with machine-checked proofs: totals do not depend on traversal order or how entries are split across workers, each hard-linked inode is charged once, rounding and block conversion match `du`, the `-h` unit rule and strings, and `-c` across operands. `just proof` builds the proofs, audits their axioms and checks `src/` against golden vectors exported from Lean. [proofs/README.md](proofs/README.md) lists what is proven, what is only tested, and what is not covered.

### Layout

| Path | Contents |
| :--- | :--- |
| `src/main.zig` | Entry point: parse, scan each operand, print |
| `src/cli.zig` | Options, argument parsing, usage, default thread count |
| `src/walk.zig` | Parallel `getattrlistbulk` walker with a `readdir`/`fstatat` fallback |
| `src/fts_walk.zig` | `fts(3)` walker for the per-entry modes (`-a`, `-d`, `-L`, `-x`, `-I`, ...), mirroring `du.c` |
| `src/accounting.zig` | Pure size math: 512-byte rounding, `howmany`, and `Scale` (du's block-size arithmetic) |
| `src/inodes.zig` | Thread-safe `(dev, ino)` set and `chargeFile`, the hard-link dedup kernel |
| `src/format.zig` | `humanize_number` clone (binary and `--si`) and output lines |
| `src/errors.zig`, `src/path.zig`, `src/sys.zig` | Diagnostics, path joining, libc and Darwin bindings |
| `tests/unit/` | Zig unit tests against the `src/` modules |
| `tests/parity/` | Black-box parity tests of the built binary against `/usr/bin/du` |
| `tests/frozen/` | Frozen Zig ports of the BSD and GNU `du` suites; edits need `ALLOW-FROZEN-EDIT` |
| `tests/upstream/` | Upstream `du` test scripts, verbatim and frozen |
| `tests/proof/` | Bridge test of `src/` against the Lean golden vectors |
| `proofs/` | Lean 4 model and proofs of the size accounting; see [proofs/README.md](proofs/README.md) |
| `bench/` | Hyperfine benchmark, fixture generator, recorded results |
| `tools/` | Comment ban, freeze check, README renderer, upstream suite runners, `EXPECTED` baseline checker |

## License

Copyright (C) 2026 Akshey Deokule. Licensed under the [GNU General Public License v3.0 or later](LICENSE) (`GPL-3.0-or-later`).

The vendored test scripts in `tests/upstream/` keep their own licenses: the FreeBSD and Apple scripts are BSD-2-Clause, and the GNU coreutils tests are GPL-3.0-or-later.
