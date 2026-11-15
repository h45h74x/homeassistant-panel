#!/bin/sh
# Runs every t_*.sh; TEST_SH=busybox runs them under "busybox sh".
here=$(cd "$(dirname "$0")" && pwd)
SH=sh
[ "$TEST_SH" = busybox ] && SH="busybox sh"
fail=0
for t in "$here"/t_*.sh; do
  echo "== $(basename "$t")"
  $SH "$t" || fail=1
done
[ $fail = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
