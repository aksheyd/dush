# dush

A fast drop-in replacement for `du -sh` on macOS.

<p align="center">
  <img src="assets/demo.gif" alt="dush terminal demo" width="800" />
</p>

## Why?

macOS `du -sh` is notoriously slow on large trees because POSIX traversal issues an individual `lstat`/`fstatat` syscall for every single file.

`dush` matches `du -sh` output byte-for-byte, but runs **~3.2x faster than `du -sh`** and **~1.3x faster than [`diskus`](https://github.com/sharkdp/diskus)**:

| Command | Mean | Min … Max | vs `dush` | Output Format |
| :--- | :---: | :---: | :---: | :--- |
| **`dush`** | **211 ms** | 200 … 219 ms | **1.00x** | `11G    /path` (exact BSD `du -sh`) |
| `diskus` | 277 ms | 259 … 290 ms | 1.31x | `10.8 GB` or raw bytes |
| `du -sh` | 669 ms | 642 … 717 ms | 3.17x | `11G    /path` |

*Measured with `hyperfine --shell none --warmup 3` on Apple Silicon (165,000 files, 18,000 dirs, ~10.8 GB).*

### How it works

- **`getattrlistbulk(2)` batching** — Reads names, file types, physical allocation sizes, and inode numbers in 64 KB kernel chunks in a single syscall (zero per-file `fstatat` overhead).
- **Work-stealing concurrency** — Traverses directory trees across all CPU cores with thread-local stacks and byte accumulators.
- **Zero-allocation traversal** — Processes file metadata directly in-place from the kernel bulk buffer without heap-allocating path strings.
- **Hardlink deduplication** — Accurately tracks multi-link inodes (`st_nlink > 1`) so hardlinks are counted exactly once.

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
make test   # Runs native Zig unit and end-to-end parity test suites
make bench  # Runs hermetic hyperfine benchmark suite (uses native Zig generator)
```

## License

[MIT](LICENSE) © 2026 Akshey Deokule
