# Sourced by start/stop/status. POSIX sh / BusyBox ash 1.17.
BIN=$(cd "$(dirname "$0")" && pwd)
PANEL_PID=${PANEL_PID:-/tmp/panel-control.pid}
PANEL_STATUS=${PANEL_STATUS:-/tmp/panel-control.status}
PANEL_TMP=${PANEL_TMP:-/tmp/panel-control.d}
PANEL_CONFIG=${PANEL_CONFIG:-$BIN/../config}
AGENT=${AGENT:-$BIN/agent.sh}
EIPS_BIN=${EIPS:-/usr/sbin/eips}
# Messages go on a fixed 5-row block of 60 columns: the first say blanks all rows, long text wraps,
# overflow ends with "...". Must not be called in a command substitution (ROW would be lost).
ROW=0; SAY_INIT=
say_row() { "$EIPS_BIN" 0 "$1" "$(printf '%-60.60s' "$2")" >/dev/null 2>&1; }
say() {
  echo "$*"
  if [ -z "$SAY_INIT" ]; then SAY_INIT=1; _r=0; while [ $_r -lt 5 ]; do say_row $_r ''; _r=$((_r+1)); done; fi
  _m=$*
  while [ -n "$_m" ] && [ $ROW -lt 5 ]; do
    if [ ${#_m} -le 60 ]; then say_row $ROW "$_m"; _m=
    elif [ $ROW -eq 4 ]; then say_row $ROW "$(printf '%.57s...' "$_m")"; _m=
    else say_row $ROW "$(printf '%.60s' "$_m")"; _m=$(printf '%s' "$_m" | cut -c61-)
    fi
    ROW=$((ROW+1))
  done
}
# is_agent <pid>: alive and (when /proc is readable) really the agent, not a reused pid
is_agent() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null || return 1
  [ -r "/proc/$1/cmdline" ] || return 0
  # cmdline is NUL-separated and grep stops at the first NUL, so turn NULs into spaces first
  # (single-char tr, no range/class; to be verified on the device in Task 5)
  tr '\000' ' ' < "/proc/$1/cmdline" | grep -q 'agent\.sh'
}
agent_pid() { # prints the pid if the agent runs
  _p=$(cat "$PANEL_PID" 2>/dev/null)
  is_agent "$_p" && echo "$_p"
}
