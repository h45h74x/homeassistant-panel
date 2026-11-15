#!/bin/sh
# Usage: deploy.sh <ssh-host>   (env SSH overrides the ssh command; GNU tar expected on this host)
case "$1" in ''|-*) echo "usage: $0 <ssh-host>" >&2; exit 1 ;; esac
HOST=$1; SSH=${SSH:-ssh}
HERE=$(cd "$(dirname "$0")" && pwd)
DEST=/mnt/us/extensions/panel-control
ARC=$(mktemp) || exit 1
trap 'rm -f "$ARC"' EXIT
# config and display.on (device state) are never shipped, so existing ones on the device are never overwritten
tar cf "$ARC" --exclude=./config --exclude=./display.on -C "$HERE/panel-control" . && tar tf "$ARC" | grep -q '^\./menu\.json$' \
  || { echo "local tar failed, nothing sent" >&2; exit 1; }
$SSH -- "$HOST" "mkdir -p $DEST && tar xf - -C $DEST" < "$ARC" || { echo "deploy failed" >&2; exit 1; }
echo "copied panel-control to $HOST:$DEST (config untouched)"
if $SSH -- "$HOST" "[ -f $DEST/config ]"; then echo "config exists on device"
else echo "no config on device yet: copy config.sample to config and fill it in"; fi
