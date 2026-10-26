#!/bin/sh
set -u
dush=${DUSH_BIN:?set DUSH_BIN to the du binary under test}
root=$(cd "$(dirname "$0")/.." && pwd)
atf_sh=$(command -v atf-sh) || { echo "upstream-bsd: atf-sh not found; brew install atf kyua" >&2; exit 2; }
command -v kyua > /dev/null || { echo "upstream-bsd: kyua not found; brew install atf kyua" >&2; exit 2; }
case $dush in /*) ;; *) dush=$PWD/$dush ;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/dush-upstream-bsd.XXXXXX")
trap 'chmod -R u+rwx "$work" 2> /dev/null; rm -rf "$work"' EXIT
mkdir "$work/bin"
ln -s "$dush" "$work/bin/du"
echo "upstream-bsd: du is $dush"
status=0
for suite in freebsd apple; do
  dir=$work/$suite
  mkdir "$dir"
  { printf '#! %s\n' "$atf_sh"; cat "$root/upstream/$suite/du_test.sh"; } > "$dir/du_test"
  chmod +x "$dir/du_test"
  printf 'syntax(2)\ntest_suite("dush-upstream-%s")\natf_test_program{name="du_test"}\n' "$suite" > "$dir/Kyuafile"
  echo "== $suite =="
  (cd "$dir" && PATH="$work/bin:$PATH" kyua --logfile="$dir/kyua.log" test --kyuafile=Kyuafile --results-file="$dir/results.db" > "$dir/test.out" 2>&1)
  rc=$?
  cat "$dir/test.out"
  test -n "${UPSTREAM_VERBOSE:-}" && kyua --logfile="$dir/kyua.log" report --verbose --results-file="$dir/results.db" --results-filter=broken,failed | awk '/^===> Execution context/ { skip = 1; next } /^===> / { skip = 0 } !skip'
  test $rc -eq 0 || status=1
done
exit $status
