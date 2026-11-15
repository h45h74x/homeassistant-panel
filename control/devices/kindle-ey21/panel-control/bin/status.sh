#!/bin/sh
. "$(dirname "$0")/launch-lib.sh"
pid=$(agent_pid)
[ -n "$pid" ] || { say "Panel Control: not running"; exit 0; }
get() { sed -n "s/^$1=//p" "$PANEL_STATUS" 2>/dev/null | head -n 1; }
st=$(get state); lc=$(get last_contact); err=$(get last_error)
msg="Panel Control: running, state=${st:-unknown}"
now=$(date +%s)
case "$lc" in
  ''|*[!0-9]*) msg="$msg, no contact yet" ;;
  *) age=$((now-lc)); msg="$msg, last contact $age s ago"
     [ $age -gt 180 ] && msg="$msg (STALE, agent may be stuck)" ;;
esac
[ -n "$err" ] && msg="$msg, error: $err"
say "$msg"
