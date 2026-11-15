#!/bin/sh
. "$(dirname "$0")/launch-lib.sh"
. "$BIN/lib.sh"
[ -r "$PANEL_CONFIG" ] || { say "No config. Create $PANEL_CONFIG from config.sample"; exit 1; }
load_config "$PANEL_CONFIG" >/dev/null   # plain text on purpose: trusted local device
say "url=$CFG_URL token=$CFG_TOKEN name=$CFG_NAME"
