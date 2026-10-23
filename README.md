# dush

A fast, drop-in replacement for `du -sh` on macOS.

<p align="center">
  <img src="assets/demo.gif" alt="dush terminal demo" width="800" />
</p>

## Why?

macOS `du -sh` is notoriously slow on large trees because POSIX traversal issues an individual `lstat`/`fstatat` syscall for every single file.

`dush` follows BSD `du -sh` formatting. On a warm Linux metadata walk it is the fastest of these tools — **4.9× `du -sh`**, **1.9× [`diskus`](https://github.com/sharkdp/diskus)**, and **1.8× [`pdu`](https://github.com/KSXGitHub/parallel-disk-usage)**:

| Command | Mean | Min … Max | vs `dush` | Output |
| :--- | :---: | :---: | :---: | :--- |
| **`dush`** | **13.8 ms** | 13.3 … 17.3 ms | **1.00×** | `1.6M    /path` |
| [`pdu`](https://github.com/KSXGitHub/parallel-disk-usage) 0.24.0 | 24.9 ms | 22.6 … 30.2 ms | 1.81× | byte bar chart |
| [`diskus`](https://github.com/sharkdp/diskus) 0.9.0 | 26.5 ms | 24.9 … 31.9 ms | 1.93× | `1650688` |
| [`dust`](https://github.com/bootandy/dust) 1.2.6 | 40.6 ms | 36.6 … 50.1 ms | 2.95× | `1.6Mi` bar chart |
| [`gdu`](https://github.com/dundee/gdu) 5.38.0 | 58.0 ms | 48.1 … 84.6 ms | 4.21× | one-line summary |
| `du -sh` (GNU 9.4) | 67.3 ms | 56.0 … 88.4 ms | 4.89× | `1.6M    /path` |
| [`dua`](https://github.com/Byron/dua-cli) 2.46.0 | 258.5 ms | 200.7 … 446.5 ms | 18.8× | per-directory list |

*Measured with `hyperfine --shell none --warmup 3` on Linux x86_64 (4 cores, ext4, warm page cache). Tree: 100,001 files, 401 directories. `dush -k` and `du -sk` both reported 1612; `diskus` and `pdu` both reported 1,650,688 bytes, matching `du -B1`. Commands: `dush`, `pdu --max-depth 1 --bytes-format plain`, `diskus`, `dust -d 0 -c`, `gdu -n -p -s -c`, `du -sh`, `dua aggregate`. `gdu`'s summary printed `0 B` on this empty-file tree; the other tools reported about 1.6 MiB.*

### How it works

- **`getattrlistbulk(2)` batching** — Reads names, file types, physical allocation sizes, and inode numbers in 64 KB kernel chunks in a single syscall (zero per-file `fstatat` overhead).
- **Work-stealing concurrency** — Traverses directory trees across all CPU cores with thread-local stacks and byte accumulators.
- **Zero-allocation traversal** — Processes file metadata directly in-place from the kernel bulk buffer without heap-allocating path strings.
- **Hardlink deduplication** — Accurately tracks multi-link inodes (`st_nlink > 1`) so hardlinks are counted exactly once.
- **Linux fast path** — `getdents64` plus parallel `fstatat64` when a directory has a wide subdirectory fan-out.

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
