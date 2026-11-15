#!/bin/sh
. "$(dirname "$0")/launch-lib.sh"
. "$BIN/lib.sh"
[ -r "$PANEL_CONFIG" ] || { say "No config: $PANEL_CONFIG"; say "Create it from config.sample"; exit 1; }
load_config "$PANEL_CONFIG" >/dev/null   # plain text on purpose: trusted local device
say "url=$CFG_URL"; say "token=$CFG_TOKEN"; say "name=$CFG_NAME"
