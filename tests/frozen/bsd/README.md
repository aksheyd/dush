# frozen/bsd

A port of every case in FreeBSD's `usr.bin/du/tests/du_test.sh` plus the cases in
Apple's `file_cmds/du/tests/du_test.sh` (an older fork of the same file, which
macOS's `du` ships with). See `LICENSE` for the original BSD-2-Clause notice.

Each step runs the original `du` command line twice in the same temp tree, once
with `/usr/bin/du` and once with `DUSH_BIN`, and requires the same stdout, the
same exit status, and the same empty or non-empty stderr. The FreeBSD cases run
with `BLOCKSIZE=K` as the original script exports it; the Apple cases leave
`BLOCKSIZE` unset as Apple's copy does. `I_flag` also keeps the original
self-check that `-I '*foo*'` output equals the output without the `foo` paths.

Run with `just frozen-bsd`. Running with `DUSH_BIN=/usr/bin/du` checks the
harness itself and should pass every case.

| Case | Original command lines | Needs from dush |
| --- | --- | --- |
| A_flag | `du -g`, `du -A -g` on a 10G sparse file | none |
| H_flag | `du -aAH testdir`, `du -aAH testdir/C` | `-a` |
| I_flag | `du -s ...`, `du -I '*foo*' -s ...` | `-I`, `BLOCKSIZE` |
| L_flag | `du -A`, `du -AL` | `BLOCKSIZE` |
| P_flag | `du -A`, `du -AP` | `BLOCKSIZE` |
| a_flag | `du -A`, `du -Aa` | `-a`, `BLOCKSIZE` |
| c_flag | `du -A foo bar`, `du -Ac foo bar` | `BLOCKSIZE` |
| d_flag | `du -A -d 0..3 d0` | `-d` |
| g_flag | `du -Ag` on 1K/1M/1G/1T sparse files | none |
| h_flag | `du -Ah` on 1K/1M/1G/1T sparse files | none |
| k_flag | `du -Ak` | none |
| l_flag | `du -A A B`, `du -Al A B` with B a hard link to A | one line per hard-linked operand, `-l` |
| m_flag | `du -Am` | none |
| n_flag | `du -An`, then `chflags nodump B` and `du -An` | `-n` |
| s_flag | `du -As` on dirs and files | `BLOCKSIZE` |
| si_flag | `du -Ah`, `du -A --si` | `--si` |
| t_flag | `du -At 10240`, `-At -10240`, `-Aat 9216`, `-Aat -9216` | `-t` threshold (dush uses `-t` for threads), `-a` |
| stdout | `du` writing into a pipe with no reader | exit 1 and a stdout error on write failure |
| apple A, H, I, g, h, k, m, si | same as FreeBSD without `BLOCKSIZE` | same as above |
| apple c_flag | `du -A foo bar`, `du -Ac foo bar` on empty files | 512-byte block default |
