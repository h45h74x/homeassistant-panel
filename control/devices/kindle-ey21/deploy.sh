#!/bin/sh
# Usage: deploy.sh <ssh-host>   (env SSH overrides the ssh command)
[ -n "$1" ] || { echo "usage: $0 <ssh-host>" >&2; exit 1; }
HOST=$1; SSH=${SSH:-ssh}
HERE=$(cd "$(dirname "$0")" && pwd)
DEST=/mnt/us/extensions/panel-control
# config is never shipped, so an existing one on the device is never overwritten
tar cf - --exclude=./config -C "$HERE/panel-control" . \
  | $SSH "$HOST" "mkdir -p $DEST && tar xf - -C $DEST" || { echo "deploy failed" >&2; exit 1; }
echo "copied panel-control to $HOST:$DEST (config untouched)"
if $SSH "$HOST" "[ -f $DEST/config ]"; then echo "config exists on device"
else echo "no config on device yet: copy config.sample to config and fill it in"; fi
