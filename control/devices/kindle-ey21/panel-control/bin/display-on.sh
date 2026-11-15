#!/bin/sh
. "$(dirname "$0")/launch-lib.sh"
. "$BIN/lib.sh"
: > "$PANEL_DISPLAY_FLAG" 2>/dev/null
load_layer 2>/dev/null && type dev_display >/dev/null 2>&1 || exit 0
st=$(sed -n 's/^state=//p' "$PANEL_STATUS" 2>/dev/null | head -n 1)
log_last2
if [ -n "$st" ]; then l1="Panel Control: $st"; else l1="Panel Control: not running"; fi
dev_display "$l1" "$LOG1" "$LOG2" >/dev/null 2>&1
exit 0
