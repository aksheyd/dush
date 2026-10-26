#!/bin/sh
REAL=${BROKEN_REAL:-/usr/bin/du}
case "${BROKEN_MODE:-}" in
order) t=$(mktemp); "$REAL" "$@" >"$t"; rc=$?; tail -r "$t" 2>/dev/null || tac "$t"; rm -f "$t"; exit "$rc" ;;
blocksize) unset BLOCKSIZE; exec "$REAL" "$@" ;;
exit) "$REAL" "$@"; exit 0 ;;
stderr) exec "$REAL" "$@" 2>/dev/null ;;
k) exec "$REAL" -k "$@" ;;
flaky) if [ -e "$BROKEN_STATE" ]; then rm -f "$BROKEN_STATE"; exec "$REAL" "$@"; fi; : >"$BROKEN_STATE"; "$REAL" "$@"; rc=$?; printf '0\tflaky\n'; exit "$rc" ;;
*) exec "$REAL" "$@" ;;
esac
