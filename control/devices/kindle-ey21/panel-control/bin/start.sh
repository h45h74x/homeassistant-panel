#!/bin/sh
. "$(dirname "$0")/launch-lib.sh"
LOCK="$PANEL_PID.lock"
_i=0
while ! mkdir "$LOCK" 2>/dev/null; do
  _i=$((_i+1))
  if [ $_i -gt 6 ]; then rmdir "$LOCK" 2>/dev/null; [ $_i -gt 8 ] && { say "start busy"; exit 1; }; fi
  sleep 1
done
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
pid=$(agent_pid) && { say "Panel Control already running (pid $pid)"; exit 0; }
. "$BIN/lib.sh"
why=$(load_config "$PANEL_CONFIG") || { say "Not started: $why"; say "Create config from config.sample"; exit 1; }
rm -rf "$PANEL_TMP" "$PANEL_STATUS" "$PANEL_PID"
PANEL_CONFIG=$PANEL_CONFIG PANEL_STATUS=$PANEL_STATUS PANEL_TMP=$PANEL_TMP sh "$AGENT" >/dev/null 2>&1 &
echo $! > "$PANEL_PID"
_i=0
while [ ! -s "$PANEL_STATUS" ] && [ $_i -lt 3 ]; do sleep 1; _i=$((_i+1)); done
st=$(sed -n 's/^state=//p' "$PANEL_STATUS" 2>/dev/null)
say "Panel Control started: ${st:-no status yet}"
