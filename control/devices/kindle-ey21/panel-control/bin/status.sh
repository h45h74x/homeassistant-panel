#!/bin/sh
. "$(dirname "$0")/launch-lib.sh"
pid=$(agent_pid)
[ -n "$pid" ] || { say "Panel Control: not running"; exit 0; }
get() { sed -n "s/^$1=//p" "$PANEL_STATUS" 2>/dev/null | head -n 1; }
st=$(get state); lc=$(get last_contact); err=$(get last_error)
say "Panel Control: running, state=${st:-unknown}"
now=$(date +%s)
case "$lc" in
  ''|*[!0-9]*) say "no contact yet" ;;
  *) age=$((now-lc)); say "last contact $age s ago"
     [ $age -gt 180 ] && say "STALE: agent may be stuck" ;;
esac
[ -n "$err" ] && say "error: $err"
exit 0
