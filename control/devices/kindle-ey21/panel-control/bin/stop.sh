#!/bin/sh
. "$(dirname "$0")/launch-lib.sh"
# descendants <pid>: /proc scan, BusyBox 1.17 may lack pkill -P
descendants() {
  for _d in /proc/[0-9]*; do
    _c=${_d#/proc/}
    _pp=$(sed 's/^.*) [A-Za-z] \([0-9]*\) .*/\1/' "$_d/stat" 2>/dev/null)
    if [ "$_pp" = "$1" ]; then echo "$_c"; descendants "$_c"; fi
  done
}
pid=$(agent_pid)
if [ -n "$pid" ]; then
  all="$pid $(descendants "$pid")"
  kill $all 2>/dev/null
  _i=0
  while kill -0 "$pid" 2>/dev/null && [ $_i -lt 3 ]; do sleep 1; _i=$((_i+1)); done
  for _k in $all; do kill -0 "$_k" 2>/dev/null && kill -9 "$_k" 2>/dev/null; done
  say "Panel Control stopped"
else
  say "Panel Control not running"
fi
rm -rf "$PANEL_PID" "$PANEL_TMP" "$PANEL_STATUS" "$PANEL_STATUS.tmp"
exit 0
