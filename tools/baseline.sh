#!/bin/sh
set -u
expected=${1:?usage: baseline.sh EXPECTED RESULTS}
results=${2:?usage: baseline.sh EXPECTED RESULTS [LOG]}
log=${3:-}
test -f "$results" || { echo "baseline: no results file $results" >&2; exit 2; }
awk -F '\t' -v exp_file="$expected" -v log_file="$log" '
  BEGIN {
    while ((getline line < exp_file) > 0) {
      if (line == "" || substr(line, 1, 1) == "#") continue
      split(line, f, "\t")
      want[f[2]] = f[1]
      why[f[2]] = f[3]
    }
  }
  {
    split($0, f, ": ")
    got = f[1]
    name = substr($0, length(got) + 3)
    seen[name] = 1
    total++
    count[got]++
    w = (name in want) ? want[name] : "PASS"
    if (got != w) {
      bad++
      printf "DEVIATION: %s: expected %s, got %s%s\n", name, w, got, (name in why) ? " (baseline reason: " why[name] ")" : ""
    }
  }
  END {
    for (name in want) if (!(name in seen)) {
      bad++
      printf "DEVIATION: %s: listed in the baseline as %s but did not run\n", name, want[name]
    }
    if (total == 0) {
      printf "baseline: no results to compare against %s\n", exp_file
      exit 1
    }
    printf "baseline: %d results (%d PASS, %d FAIL, %d SKIP); %d deviation(s) from %s\n", total, count["PASS"], count["FAIL"], count["SKIP"], bad, exp_file
    if (bad) {
      if (log_file != "") printf "baseline: details in %s\n", log_file
      printf "baseline: fix the regression, or if the new outcome is intended and matches /usr/bin/du, update %s with a reason\n", exp_file
      exit 1
    }
  }
' "$results"
