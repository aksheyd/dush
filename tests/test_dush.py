#!/usr/bin/env python3
"""
Comprehensive test suite for `dush`.
Validates behavioral and numerical equivalence between `dush` and macOS `du -sh`.
"""

import os
import sys
import tempfile
import subprocess
import unittest

REPO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUSH_BIN = os.path.join(REPO_DIR, "dush")

class TestDush(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Ensure binary exists and is up to date
        subprocess.run(["make", "all"], cwd=REPO_DIR, check=True)
        assert os.path.exists(DUSH_BIN), f"dush binary not found at {DUSH_BIN}"

    def run_cmd(self, cmd):
        res = subprocess.run(cmd, capture_output=True, text=True)
        return res.returncode, res.stdout, res.stderr

    def test_default_dot(self):
        rc1, out1, _ = self.run_cmd([DUSH_BIN])
        rc2, out2, _ = self.run_cmd(["du", "-sh"])
        self.assertEqual(rc1, 0)
        self.assertEqual(rc2, 0)
        self.assertEqual(out1.strip(), out2.strip())

    def test_single_directory(self):
        rc1, out1, _ = self.run_cmd([DUSH_BIN, ".git"])
        rc2, out2, _ = self.run_cmd(["du", "-sh", ".git"])
        self.assertEqual(rc1, 0)
        self.assertEqual(rc2, 0)
        self.assertEqual(out1.strip(), out2.strip())

    def test_multiple_arguments(self):
        with tempfile.TemporaryDirectory() as td:
            d1 = os.path.join(td, "dir1")
            d2 = os.path.join(td, "dir2")
            f1 = os.path.join(td, "file1.txt")
            os.makedirs(d1)
            os.makedirs(d2)
            with open(os.path.join(d1, "test.bin"), "wb") as f:
                f.write(b"a" * 50000)
            with open(os.path.join(d2, "test2.bin"), "wb") as f:
                f.write(b"b" * 120000)
            with open(f1, "wb") as f:
                f.write(b"c" * 1000)

            rc1, out1, _ = self.run_cmd([DUSH_BIN, d1, d2, f1])
            rc2, out2, _ = self.run_cmd(["du", "-sh", d1, d2, f1])
            self.assertEqual(rc1, 0)
            self.assertEqual(rc2, 0)
            self.assertEqual(out1.strip(), out2.strip())

    def test_flags_sh_hs(self):
        rc1, out1, _ = self.run_cmd([DUSH_BIN, "-sh", ".git"])
        rc2, out2, _ = self.run_cmd([DUSH_BIN, "-hs", ".git"])
        rc3, out3, _ = self.run_cmd(["du", "-sh", ".git"])
        self.assertEqual(rc1, 0)
        self.assertEqual(rc2, 0)
        self.assertEqual(rc3, 0)
        self.assertEqual(out1.strip(), out3.strip())
        self.assertEqual(out2.strip(), out3.strip())

    def test_grand_total(self):
        with tempfile.TemporaryDirectory() as td:
            d1 = os.path.join(td, "a")
            d2 = os.path.join(td, "b")
            os.makedirs(d1)
            os.makedirs(d2)
            with open(os.path.join(d1, "f"), "wb") as f: f.write(b"x" * 20000)
            with open(os.path.join(d2, "g"), "wb") as f: f.write(b"y" * 40000)

            rc1, out1, _ = self.run_cmd([DUSH_BIN, "-c", d1, d2])
            rc2, out2, _ = self.run_cmd(["du", "-sh", "-c", d1, d2])
            self.assertEqual(rc1, 0)
            self.assertEqual(rc2, 0)
            self.assertEqual(out1.strip(), out2.strip())

    def test_block_sizes(self):
        with tempfile.TemporaryDirectory() as td:
            with open(os.path.join(td, "file"), "wb") as f:
                f.write(b"z" * 200000)

            for flag in ["-k", "-m", "-g"]:
                rc1, out1, _ = self.run_cmd([DUSH_BIN, flag, td])
                rc2, out2, _ = self.run_cmd(["du", "-s" + flag[1:], td])
                self.assertEqual(rc1, 0)
                self.assertEqual(rc2, 0)
                self.assertEqual(out1.strip(), out2.strip())

    def test_apparent_size(self):
        with tempfile.TemporaryDirectory() as td:
            p = os.path.join(td, "sparse.bin")
            with open(p, "wb") as f:
                f.truncate(10 * 1024 * 1024) # 10MB sparse
            # odd size: du -A rounds each entry up to 512-byte blocks,
            # so this only matches if dush rounds the same way
            with open(os.path.join(td, "odd.bin"), "wb") as f:
                f.write(b"z" * 1000)

            rc1, out1, _ = self.run_cmd([DUSH_BIN, "-A", td])
            rc2, out2, _ = self.run_cmd(["du", "-sh", "-A", td])
            self.assertEqual(rc1, 0)
            self.assertEqual(rc2, 0)
            self.assertEqual(out1.strip(), out2.strip())

    def test_hardlinks(self):
        with tempfile.TemporaryDirectory() as td:
            f1 = os.path.join(td, "f1")
            with open(f1, "wb") as f:
                f.write(b"q" * 65536)
            f2 = os.path.join(td, "f2")
            os.link(f1, f2)

            rc1, out1, _ = self.run_cmd([DUSH_BIN, td])
            rc2, out2, _ = self.run_cmd(["du", "-sh", td])
            self.assertEqual(rc1, 0)
            self.assertEqual(rc2, 0)
            self.assertEqual(out1.strip(), out2.strip())

    def test_symlinks(self):
        with tempfile.TemporaryDirectory() as td:
            target = os.path.join(td, "target")
            os.makedirs(target)
            with open(os.path.join(target, "file"), "wb") as f:
                f.write(b"w" * 50000)
            link = os.path.join(td, "link")
            os.symlink(target, link)

            # Default: -P (no follow)
            rc1, out1, _ = self.run_cmd([DUSH_BIN, link])
            rc2, out2, _ = self.run_cmd(["du", "-sh", link])
            self.assertEqual(rc1, 0)
            self.assertEqual(rc2, 0)
            self.assertEqual(out1.strip(), out2.strip())

            # -L (follow all)
            rc1, out1, _ = self.run_cmd([DUSH_BIN, "-L", link])
            rc2, out2, _ = self.run_cmd(["du", "-sh", "-L", link])
            self.assertEqual(rc1, 0)
            self.assertEqual(rc2, 0)
            self.assertEqual(out1.strip(), out2.strip())

            # -H (follow command line symlink)
            rc1, out1, _ = self.run_cmd([DUSH_BIN, "-H", link])
            rc2, out2, _ = self.run_cmd(["du", "-sh", "-H", link])
            self.assertEqual(rc1, 0)
            self.assertEqual(rc2, 0)
            self.assertEqual(out1.strip(), out2.strip())

    def test_nonexistent(self):
        rc, _, err = self.run_cmd([DUSH_BIN, "non_existent_path_xyz_123"])
        self.assertEqual(rc, 1)
        self.assertIn("No such file or directory", err)

    def test_deep_hierarchy(self):
        with tempfile.TemporaryDirectory() as td:
            cur = td
            for depth in range(20):
                cur = os.path.join(cur, f"sub_{depth}")
                os.makedirs(cur)
                with open(os.path.join(cur, "dummy.txt"), "w") as f:
                    f.write(f"depth {depth}\n" * 50)

            rc1, out1, _ = self.run_cmd([DUSH_BIN, td])
            rc2, out2, _ = self.run_cmd(["du", "-sh", td])
            self.assertEqual(rc1, 0)
            self.assertEqual(rc2, 0)
            self.assertEqual(out1.strip(), out2.strip())

if __name__ == "__main__":
    unittest.main()
