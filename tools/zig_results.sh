#!/bin/sh
set -u
log=${1:?usage: zig_results.sh ZIG_TEST_LOG}
awk '
  function emit(r) {
    if (r == "OK") r = "PASS"
    else if (r == "SKIP") r = "SKIP"
    else r = "FAIL"
    print r ": " name
    done++
    name = ""
  }
  /^[0-9]+\/[0-9]+ / {
    if (name != "") emit("CRASH")
    line = $0
    split(line, nm, " ")
    split(nm[1], frac, "/")
    total = frac[2]
    sub(/^[0-9]+\/[0-9]+ /, "", line)
    i = index(line, "...")
    name = substr(line, 1, i - 1)
    rest = substr(line, i + 3)
    if (rest == "OK" || rest == "SKIP" || rest ~ /^FAIL( |$)/) emit(rest)
    next
  }
  name != "" && ($0 == "OK" || $0 == "SKIP" || $0 ~ /^FAIL \(/) { emit($0) }
  END {
    if (name != "") emit("CRASH")
    if (total == 0 || done != total) {
      printf "zig_results: parsed %d of %d tests from %s\n", done, total, FILENAME > "/dev/stderr"
      exit 1
    }
  }
' "$log"
