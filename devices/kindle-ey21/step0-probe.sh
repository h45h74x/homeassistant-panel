#!/bin/sh
# Step-0 probe for Control (read-only). Run from the computer so output stays off the device:
#   ssh kindle-pw1 'sh -s' < devices/kindle-ey21/step0-probe.sh > devices/kindle-ey21/step0-output.txt
# Redact serial, MAC and IP before committing the output (docs/probing-devices.md).
# Answers: which tools exist (jq? awk? sed?), and how search-bar commands could be routed.
# BusyBox 1.17.1: no `grep -E`, no `nohup`. Nothing here writes to the device.

echo "## alive"; uptime
echo "## tools (path or MISSING)"
for t in jq python python3 perl lua awk sed tr cut od hexdump base64 md5sum sha1sum sha256sum openssl curl wget nc timeout date eips fbink flock sort head tail xargs printf mktemp; do
  p=$(which $t 2>/dev/null); echo "$t=${p:-MISSING}"
done
echo "## busybox applets"; busybox --list 2>/dev/null | tr '\n' ' '; echo
echo "## curl"; curl --version 2>&1 | head -2
echo "## curl can send a body from stdin and headers"; curl --help 2>&1 | head -40 | sed -n 1,3p
echo "## sh features"; sh -c 'x=abc; echo ${#x} ${x#a}' 2>&1
echo "## sed -n regex (needed to parse JSON)"; echo '{"a":"b","id":7}' | sed -n 's/.*"id":\([0-9]*\).*/\1/p'
echo "## paths"
ls -d /mnt/us/mkk /mnt/us/extensions /mnt/us/documents /mnt/us/usbnet /mnt/us/kmc /var/local/kmc /mnt/us/linkss /mnt/us/koreader 2>&1
echo "## extensions"; ls /mnt/us/extensions 2>&1
echo "## documents (scriptlets are *.sh here)"; ls /mnt/us/documents 2>&1 | head -30
echo "## mkk / dispatch (search-bar command routing)"
ls -la /mnt/us/mkk 2>&1 | head -20
find /mnt/us/mkk /mnt/us/extensions /mnt/us/usbnet /var/local/kmc -maxdepth 3 -iname '*dispatch*' 2>/dev/null
find /mnt/us/mkk /mnt/us/extensions /mnt/us/documents -maxdepth 3 \( -iname '*.sh' -o -iname '*.json' \) 2>/dev/null | head -40
echo "## things that mention 'log' commands"
for f in /mnt/us/mkk/dispatch.sh /mnt/us/mkk/*.sh; do [ -f "$f" ] && { echo "--- $f"; head -60 "$f"; }; done 2>/dev/null
echo "## stock command table (search bar ';' commands)"
ls -l /app/kpp_app_cmds.json /opt/amazon/ebook/kpp_app_cmds.json 2>&1
echo "## upstart jobs mentioning mkk, dispatch or log"
ls /etc/upstart 2>/dev/null | head -50
echo "## free space"; df -k /mnt/us /; free 2>/dev/null | head -3

# Manual follow-up (cannot be scripted): in the Kindle home search bar type
#   ;log step0test a b c
# then re-run only the "mkk / dispatch" section and look for what changed (new log lines,
# /var/log/messages, /tmp). The question is whether a script ever sees "a b c".
