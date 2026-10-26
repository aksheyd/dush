#!/bin/sh
set -u
dush=${DUSH_BIN:?set DUSH_BIN to the du binary under test}
root=$(cd "$(dirname "$0")/.." && pwd)
gnu=$root/tests/upstream/gnu
version=$(sed -n 's/^coreutils \([0-9.]*\).*/\1/p' "$gnu/VERSION")
gnubin=${GNUBIN:-$(brew --prefix coreutils 2> /dev/null)/libexec/gnubin}
test -x "$gnubin/stat" || { echo "upstream-gnu: GNU coreutils not found at $gnubin; brew install coreutils or set GNUBIN" >&2; exit 2; }
perl=$(command -v perl) || { echo "upstream-gnu: perl not found" >&2; exit 2; }
case $dush in /*) ;; *) dush=$PWD/$dush ;; esac
if test -n "${UPSTREAM_LOGS:-}"; then
  work=$UPSTREAM_LOGS
  mkdir -p "$work"
else
  work=$(mktemp -d "${TMPDIR:-/tmp}/dush-upstream-gnu.XXXXXX")
  trap 'chmod -R u+rwx "$work" 2> /dev/null; rm -rf "$work"' EXIT
fi
stage=$work/stage
mkdir -p "$stage/src" "$work/logs"
cp "$gnu/init.cfg" "$stage/init.cfg"
ln -sfn "$gnu/tests" "$stage/tests"
ln -sf "$dush" "$stage/src/du"
ln -sf "$root/tools/getlimits.pl" "$stage/src/getlimits"
printf '#define HAVE_OPENAT 1\n' > "$stage/config.h"
built=$(ls "$gnubin" | tr '\n' ' ')
echo "upstream-gnu: du is $dush; coreutils $version tests; other tools from $gnubin"
pass=0 fail=0 skip=0 error=0
for t in "$gnu"/tests/du/*.sh "$gnu"/tests/du/*.pl; do
  name=tests/du/${t##*/}
  log=$work/logs/${t##*/}.log
  (
    cd "$stage" || exit 99
    . ./tests/lang-default
    tmp__=${TMPDIR-/tmp}
    test -d "$tmp__" && test -w "$tmp__" || tmp__=.
    . ./tests/envvar-check
    TMPDIR=$tmp__
    export TMPDIR
    export VERSION="$version" abs_top_builddir="$stage" abs_top_srcdir="$stage" abs_srcdir="$stage" \
      built_programs="$built" fail=0 host_os=darwin srcdir=. top_srcdir=. CONFIG_HEADER="$stage/config.h" \
      CU_TEST_NAME="tests,$(echo "$name" | sed 's,/,-,g')" CC=cc AWK=awk EGREP='grep -E' EXEEXT= MAKE=make \
      PACKAGE_VERSION="$version" PERL="$perl" SHELL=/bin/sh
    PATH=$stage/src:$gnubin:$PATH
    export PATH
    case $name in
      *.pl) exec "$perl" -w -I./tests -MCuSkip -MCoreutils -M"CuTmpdir qw($name)" -- "$name" ;;
      *) exec /bin/sh "$name" ;;
    esac
  ) > "$log" 2>&1 < /dev/null
  rc=$?
  case $rc in
    0) result=PASS pass=$((pass + 1)) ;;
    77) result=SKIP skip=$((skip + 1)) ;;
    99) result=ERROR error=$((error + 1)) ;;
    *) result=FAIL fail=$((fail + 1)) ;;
  esac
  echo "$result: $name"
  case $result in
    FAIL | ERROR) test -n "${UPSTREAM_VERBOSE:-}" && sed 's/^/    /' "$log" ;;
  esac
done
echo "upstream-gnu: $pass pass, $fail fail, $skip skip, $error error"
test $((fail + error)) -eq 0
