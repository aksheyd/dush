# Upstream du test suites

Test scripts copied verbatim, license headers intact, from the projects whose
`du` dush aims to match. Nothing in this directory is edited; the runners in
`tools/` adapt the environment instead. The comment ban skips this directory.

| Directory | Source | Pin | License |
| :--- | :--- | :--- | :--- |
| `freebsd/du_test.sh` | [freebsd-src `usr.bin/du/tests/du_test.sh`](https://github.com/freebsd/freebsd-src/blob/73e0d6b44038d1c7764c5013a54ae17a8f680a69/usr.bin/du/tests/du_test.sh) | commit `73e0d6b44038d1c7764c5013a54ae17a8f680a69` | BSD-2-Clause (header) |
| `apple/du_test.sh` | [apple-oss-distributions/file_cmds `du/tests/du_test.sh`](https://github.com/apple-oss-distributions/file_cmds/blob/file_cmds-479/du/tests/du_test.sh) | tag `file_cmds-479` (`659a8a301e2acf0343f8b8673a154a2ca4d07084`) | BSD-2-Clause (header) |
| `gnu/` | [GNU coreutils 9.12](https://ftp.gnu.org/gnu/coreutils/coreutils-9.12.tar.xz) `tests/du/*` plus the harness files they need | release 9.12, tarball sha256 in `gnu/VERSION` | GPL-3.0-or-later (`gnu/COPYING`) |

## Running

`just upstream-bsd` builds dush, puts a `du -> dush` symlink first on `PATH`,
prepends the `atf-sh` interpreter line exactly as FreeBSD's `atf.test.mk` does,
and runs each script with `kyua test`. Needs `brew install atf kyua`. The
scripts export `BLOCKSIZE=K` themselves.

`just upstream-gnu` stages a tree shaped like a coreutils build (`init.cfg`,
`tests/`, `src/du -> dush`, `src/getlimits`), exports the same variables as
coreutils' `TESTS_ENVIRONMENT`, and runs each `.sh` with `/bin/sh` and the
`.pl` with coreutils' perl options. It reports PASS, FAIL, SKIP or ERROR per
script. The other tools the scripts call (`stat`, `truncate`, `seq`, ...) come
from Homebrew's GNU coreutils (`brew install coreutils`), as they would from the
coreutils build tree. `src/getlimits` is `tools/getlimits.pl`, a small stand-in
for coreutils' unbuilt `getlimits` helper that prints the integer limits and
errno strings the scripts read.

Set `DUSH_BIN=/usr/bin/du` to run either suite against macOS's `du`,
`UPSTREAM_VERBOSE=1` to print failure details, and `UPSTREAM_LOGS=dir` to keep
the GNU logs.
