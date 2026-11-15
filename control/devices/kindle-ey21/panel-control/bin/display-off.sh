#!/bin/sh
. "$(dirname "$0")/launch-lib.sh"
[ -f "$PANEL_DISPLAY_FLAG" ] || exit 0   # nothing drawn, so nothing to clear (each clear is 3 e-ink refreshes)
rm -f "$PANEL_DISPLAY_FLAG" 2>/dev/null
load_layer 2>/dev/null && type dev_display_clear >/dev/null 2>&1 && dev_display_clear >/dev/null 2>&1
exit 0
