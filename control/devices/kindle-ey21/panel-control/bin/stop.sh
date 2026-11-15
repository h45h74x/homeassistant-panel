#!/bin/sh
. "$(dirname "$0")/launch-lib.sh"
# descendants <pid>: all children, grandchildren, ... without forks (BusyBox 1.17 may lack pkill -P).
# One pass over /proc per tree level; /proc/<pid>/stat is "pid (name) S ppid ...", name may contain spaces.
descendants() {
  _lvl=$1; _out=
  while [ -n "$_lvl" ]; do
    _next=
    for _d in /proc/[0-9]*; do
      { read -r _l < "$_d/stat"; } 2>/dev/null || continue
      _l=${_l##*) }; set -- $_l
      for _p in $_lvl; do [ "$2" = "$_p" ] && { _next="$_next ${_d#/proc/}"; break; }; done
    done
    _out="$_out$_next"; _lvl=$_next
  done
  echo $_out
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
