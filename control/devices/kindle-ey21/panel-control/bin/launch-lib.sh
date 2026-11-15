# Sourced by start/stop/status. POSIX sh / BusyBox ash 1.17.
BIN=$(cd "$(dirname "$0")" && pwd)
PANEL_PID=${PANEL_PID:-/tmp/panel-control.pid}
PANEL_STATUS=${PANEL_STATUS:-/tmp/panel-control.status}
PANEL_TMP=${PANEL_TMP:-/tmp/panel-control.d}
PANEL_CONFIG=${PANEL_CONFIG:-$BIN/../config}
AGENT=${AGENT:-$BIN/agent.sh}
EIPS_BIN=${EIPS:-/usr/sbin/eips}
ROW=0
say() { echo "$*"; "$EIPS_BIN" 0 "$ROW" "$(printf "%-60.60s" "$*")" >/dev/null 2>&1; ROW=$((ROW+1)); }
# is_agent <pid>: alive and (when /proc is readable) really the agent, not a reused pid
is_agent() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null || return 1
  [ -r "/proc/$1/cmdline" ] || return 0
  grep -q 'agent\.sh' "/proc/$1/cmdline"
}
agent_pid() { # prints the pid if the agent runs
  _p=$(cat "$PANEL_PID" 2>/dev/null)
  is_agent "$_p" && echo "$_p"
}
