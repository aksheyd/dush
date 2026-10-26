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
| `dush -t10` | 147.5 ms | 143.8 … 151.1 ms | 1.24x | `11G    /path` |
| `diskus` | 239.5 ms | 229.0 … 272.7 ms | 2.02x | `11419648000` |
| `du -sh` | 443.0 ms | 438.7 … 452.7 ms | 3.73x | `11G    /path` |

*Measured with `hyperfine --shell none --warmup 3` on an Apple M4 (4 performance cores), 164,000 files, 18,001 directories, 11G, warm cache. The default worker count is those 4 cores. `dush -t10` uses every logical core.*

GNU coreutils 9.12 (`gdu -sh`) took 457.0 ms (453.2 … 466.9 ms) on that same tree. On the small bench fixture (16,410 files, 667 directories, 4.8M) dush took 8.0 ms, diskus 16.5 ms, and `du -sh` 23.3 ms.

### How it works

- **`getattrlistbulk(2)` batching** — Reads names, file types, physical allocation sizes, and inode numbers in 64 KB kernel chunks in a single syscall. `fstatat` runs only when that call omits the size. Apparent size (`-A`) reads each entry's data length from the same call.
- **Work-stealing concurrency** — Traverses directory trees with thread-local stacks and byte accumulators. On Apple Silicon the default is the performance-core count; `-t` sets the worker count explicitly.
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

### Flags

| Flag | Description |
| :--- | :--- |
| `-s`, `-h` | Summary total with human-readable units (`B`, `K`, `M`, `G`) — enabled by default |
| `-c` | Display a grand total row at the end |
| `-A` | Apparent size (file length) rather than physical disk usage |
| `-k`, `-m`, `-g` | Block size units (1 KiB, 1 MiB, 1 GiB) |
| `-P` | Do not follow symlinks (default) |
| `-H` | Follow symlinks specified on the command line |
| `-L` | Follow all symlinks encountered during traversal |

## Verification

`dush` is tested against BSD `du -sh` for 100% numerical and formatting parity:

```sh
just test   # Same checks as CI: comment ban, Zig tests, frozen du suite, freeze check, README check, ported BSD and GNU du suites, upstream du suites
make bench  # Runs hermetic hyperfine benchmark suite (uses native Zig generator)
```

`upstream/` holds the FreeBSD, Apple and GNU coreutils `du` test scripts copied verbatim. `just upstream-bsd` runs the ATF scripts under kyua and `just upstream-gnu` runs the coreutils scripts with their own harness, both with `du` resolving to `dush`; see [upstream/README.md](upstream/README.md).

## License

Copyright (C) 2026 Akshey Deokule. Licensed under the [GNU General Public License v3.0 or later](LICENSE) (`GPL-3.0-or-later`).

The vendored test scripts in `upstream/` keep their own licenses: the FreeBSD and Apple scripts are BSD-2-Clause, and the GNU coreutils tests are GPL-3.0-or-later.
