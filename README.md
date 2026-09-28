# dush — a faster `du -sh` for macOS

A fast, drop-in replacement for `du -sh` written in Zig (0.16) using multi-threaded work-stealing and macOS `getattrlistbulk(2)` batch metadata syscalls.

## Quick Start

```sh
make                # builds release binary ./dush (requires zig 0.16.x)
./dush [FILE/DIR]   # drop-in replacement for du -sh
make install        # installs to /usr/local/bin (or PREFIX=/path)
```

## Benchmarks (`hyperfine`, Apple Silicon, macOS)

Benchmarked hermetically with `hyperfine --shell none --warmup 3` across interleaved runs to guarantee cache fairness and statistical isolation. Output parity verified before timing (`dush == du -sh`).

### 1. Real-World Workload (GitHub Repos: 165,000 files, 18,000 dirs, ~10.8 GB)

| Command | Mean [ms] | Min [ms] | Max [ms] | Relative Speed |
|:---|---:|---:|---:|---:|
| **`dush`** | **211.2 ± 5.9** | **200.5** | **219.1** | **1.00** (fastest) |
| `diskus` | 277.0 ± 9.8 | 259.3 | 289.9 | 1.31x slower |
| `du -sh` | 669.4 ± 31.0 | 642.3 | 716.9 | 3.17x slower |

*Summary:* **`dush` runs 3.17x faster than `du -sh` and 1.31x faster than [`diskus`](https://github.com/sharkdp/diskus)**.

---

### 2. Mixed Synthetic Fixture (Edge cases, deep recursion, sparse files, symlinks, hardlinks)

| Command | Mean [ms] | Min [ms] | Max [ms] | Relative Speed |
|:---|---:|---:|---:|---:|
| **`dush`** | **16.4 ± 2.5** | **12.8** | **29.7** | **1.00** (fastest) |
| `diskus` | 24.8 ± 2.2 | 19.7 | 28.6 | 1.51x slower |
| `du -sh` | 41.7 ± 3.3 | 37.5 | 52.2 | 2.54x slower |

---

### Comparison with [diskus](https://github.com/sharkdp/diskus) and other tools

In [diskus's benchmarks](https://github.com/sharkdp/diskus#benchmark), diskus was shown to outperform `du -sh` (cold ~10x, warm ~2.2x), as well as [dust](https://github.com/bootandy/dust) and [tin-summer](https://github.com/vmchale/tin-summer).

`dush` achieves even higher speed on macOS because:
1. **`getattrlistbulk(2)`**: Rather than calling `fstatat` or `lstat` individually for every file in a directory, `dush` fetches file names, types, allocation sizes, and inode IDs in 64KB kernel batches in a single syscall.
2. **Zero-allocation file traversal**: Path strings are only allocated for subdirectories; file metadata is processed in-place directly from the bulk buffer.
3. **Exact `du -sh` format**: `diskus` outputs in its own custom format or raw bytes, whereas `dush` produces byte-for-byte identical output to BSD `du -sh` (`0B`, `1.0K`, `49K`, `1.5M`, `10G`), making it a drop-in alias for `du -sh`.
