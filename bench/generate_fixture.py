#!/usr/bin/env python3
"""
Synthetic directory tree generator for benchmarking `dush`.

Generates a deterministically structured directory tree with:
- Multi-level directory hierarchies
- Thousands of files with pseudo-random allocation sizes
- Sparse files (zero-filled extents via ftruncate)
- Deep directory recursion chains (path length & stack depth testing)
- Hardlinked files (verifying inode deduplication)
- Relative and dangling symbolic links (verifying symlink traversal rules)
"""

import argparse
import os
import shutil
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate a synthetic directory tree fixture for dush benchmarking."
    )
    parser.add_argument(
        "destination",
        nargs="?",
        default=".bench/tree",
        help="Destination directory for fixture (default: .bench/tree)",
    )
    parser.add_argument(
        "--top-dirs",
        type=int,
        default=128,
        help="Number of top-level directories (default: 128)",
    )
    parser.add_argument(
        "--files-per-top",
        type=int,
        default=64,
        help="Number of files per top directory (default: 64)",
    )
    parser.add_argument(
        "--sub-per-top",
        type=int,
        default=4,
        help="Number of subdirectories per top directory (default: 4)",
    )
    parser.add_argument(
        "--files-per-sub",
        type=int,
        default=16,
        help="Number of files per subdirectory (default: 16)",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        default=True,
        help="Wipe destination directory if it already exists (default: True)",
    )
    return parser.parse_args()


class DeterministicRNG:
    """64-bit Linear Congruential Generator for reproducible file size distributions."""

    def __init__(self, seed: int = 0x12345678):
        self.state = seed & 0xFFFFFFFFFFFFFFFF

    def next(self, modulo: int) -> int:
        self.state = (self.state * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
        return self.state % modulo


def generate_fixture(
    dest: str,
    top_dirs: int = 128,
    files_per_top: int = 64,
    sub_per_top: int = 4,
    files_per_sub: int = 16,
    clean: bool = True,
) -> tuple[int, int]:
    dest = os.path.abspath(dest)
    if clean and os.path.exists(dest):
        shutil.rmtree(dest)

    os.makedirs(dest, exist_ok=True)
    rng = DeterministicRNG()
    total_files = 0
    total_dirs = 0

    # 1. Broad directory hierarchy with varied file sizes and sparse files
    for i in range(top_dirs):
        top_dir = os.path.join(dest, f"d{i:03d}")
        os.makedirs(top_dir, exist_ok=True)
        total_dirs += 1

        for j in range(files_per_top):
            file_path = os.path.join(top_dir, f"f{j:04d}")
            size = 512 + rng.next(32 * 1024)
            fd = os.open(file_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
            if (i + j) % 31 == 0:
                # Sparse file: write header chunk, then ftruncate out to large size
                os.write(fd, b"x" * min(4096, size))
            os.ftruncate(fd, size)
            os.close(fd)
            total_files += 1

        for s in range(sub_per_top):
            sub_dir = os.path.join(top_dir, f"s{s}")
            os.makedirs(sub_dir, exist_ok=True)
            total_dirs += 1

            for j in range(files_per_sub):
                file_path = os.path.join(sub_dir, f"g{j:04d}")
                size = 512 + rng.next(16 * 1024)
                fd = os.open(file_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
                os.ftruncate(fd, size)
                os.close(fd)
                total_files += 1

    # 2. Deep recursion edge case (25 levels deep)
    deep_path = os.path.join(dest, "deep")
    for depth in range(25):
        deep_path = os.path.join(deep_path, f"sub_{depth}")
        os.makedirs(deep_path, exist_ok=True)
        total_dirs += 1
        with open(os.path.join(deep_path, "dummy.txt"), "w") as f:
            f.write(f"depth {depth}\n" * 20)
        total_files += 1

    # 3. Hardlink edge case (verifies inode deduplication)
    src_file = os.path.join(dest, "d000", "f0000")
    if os.path.exists(src_file):
        os.link(src_file, os.path.join(dest, "d000", "hardlink_to_f0000"))
        total_files += 1

    # 4. Symlink edge cases (directory symlink, file symlink, dangling symlink)
    os.symlink(os.path.join(dest, "d001"), os.path.join(dest, "link_to_dir"))
    os.symlink(os.path.join(dest, "d002", "f0001"), os.path.join(dest, "link_to_file"))
    os.symlink(os.path.join(dest, "nonexistent"), os.path.join(dest, "dangling"))
    total_files += 3

    return total_files, total_dirs


def main() -> None:
    args = parse_args()
    print(f"Generating fixture at: {args.destination}")
    nfiles, ndirs = generate_fixture(
        dest=args.destination,
        top_dirs=args.top_dirs,
        files_per_top=args.files_per_top,
        sub_per_top=args.sub_per_top,
        files_per_sub=args.files_per_sub,
        clean=args.clean,
    )
    print(f"Fixture ready: {nfiles:,} files across {ndirs:,} directories.")


if __name__ == "__main__":
    main()
