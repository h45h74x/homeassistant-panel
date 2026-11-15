#!/bin/sh
. "$(dirname "$0")/launch-lib.sh"
. "$BIN/lib.sh"
true > "$PANEL_DISPLAY_FLAG" 2>/dev/null || exit 0
load_layer 2>/dev/null && type dev_display >/dev/null 2>&1 || exit 0
log_last2
l1="Panel Control: not running"
if [ -n "$(agent_pid)" ]; then
  st=$(sed -n 's/^state=//p' "$PANEL_STATUS" 2>/dev/null | head -n 1)
  l1="Panel Control: ${st:-running}"
fi
dev_display "$l1" "$LOG1" "$LOG2" >/dev/null 2>&1
exit 0
