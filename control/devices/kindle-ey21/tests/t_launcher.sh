#!/bin/sh
# Launcher scripts with a stub eips and a fake agent (sleep loop).
here=$(cd "$(dirname "$0")" && pwd)
PKG="$here/../panel-control"; BIN="$PKG/bin"
T=$(mktemp -d); FAILS=0
cleanup() { for p in $(cat "$T"/*/pid 2>/dev/null); do kill "$p" 2>/dev/null; done; pkill -f "$T/" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
ok() { _n=$1; shift; "$@" >/dev/null 2>&1 || { FAILS=$((FAILS+1)); echo "FAIL $_n"; [ -f "$D/eips.log" ] && sed 's/^/    eips: /' "$D/eips.log"; }; }
has() { grep -q -e "$1" "$D/eips.log"; }
begin() { # <name> [good-config]
  D="$T/$1"; mkdir -p "$D/bin"; : > "$D/eips.log"
  printf '#!/bin/sh\necho "$*" >> "%s/eips.log"\n' "$D" > "$D/eips"
  chmod +x "$D/eips"
  # fake agent: writes a status file, then sleeps with a child
  cat > "$D/bin/agent.sh" <<EOT
#!/bin/sh
mkdir -p "\$PANEL_TMP"; echo secret > "\$PANEL_TMP/curl.cfg"
printf 'state=running\nlast_contact=%s\nlast_error=\nagent_version=t\n' "\$(date +%s)" > "\$PANEL_STATUS"
while :; do sleep 1; done
EOT
  export PANEL_PID="$D/pid" PANEL_STATUS="$D/status" PANEL_TMP="$D/tmp" PANEL_CONFIG="$D/config" EIPS="$D/eips" AGENT="$D/bin/agent.sh"
  [ "$2" = nocfg ] || printf 'url = http://10.0.0.1:8123/api/x\r\ntoken = "abc123"\r\ndevice_name = Kit\r\n' > "$D/config"
}
alive() { kill -0 "$(cat "$PANEL_PID" 2>/dev/null)" 2>/dev/null; }
nagents() { pgrep -f "$D/bin/agent.sh" | wc -l; }
eq() { [ "$1" = "$2" ]; }

begin t1
sh "$BIN/start.sh" >/dev/null
ok start_creates_pidfile_and_runs alive
ok start_shows_state has 'started: running'
ok start_dir_has_curlcfg test -f "$PANEL_TMP/curl.cfg"

sh "$BIN/start.sh" >/dev/null
ok second_start_says_already_running has 'already running'
ok second_start_single_process eq "$(nagents)" 1
sh "$BIN/status.sh" >/dev/null
ok status_prints_state_and_last_contact has 'state=running, last contact [0-9]* s ago'
ok status_not_stale sh -c "! grep -q STALE '$D/eips.log'"
kill_child_test=$(pgrep -P "$(cat "$PANEL_PID")" sleep | head -n 1)
sh "$BIN/stop.sh" >/dev/null; rc=$?
ok stop_kills_agent sh -c "! kill -0 $(cat "$D/pid" 2>/dev/null || echo 99999999) 2>/dev/null"
ok stop_removes_files sh -c "[ ! -e '$PANEL_PID' ] && [ ! -e '$PANEL_TMP' ] && [ ! -e '$PANEL_STATUS' ]"
ok stop_kills_children sh -c "[ -z '$kill_child_test' ] || ! kill -0 $kill_child_test 2>/dev/null"
ok stop_zero eq $rc 0
ok no_agent_left eq "$(nagents)" 0

begin t2
sh "$BIN/stop.sh" >/dev/null; rc=$?
ok stop_when_not_running_is_ok eq $rc 0
ok stop_says_not_running has 'not running'
sh "$BIN/status.sh" >/dev/null
ok status_not_running has 'not running'

begin t3 nocfg
sh "$BIN/start.sh" >/dev/null; rc=$?
ok no_config_rc eq $rc 1
ok no_config_message has 'config.sample'
ok no_config_not_started eq "$(nagents)" 0
printf 'url = http://10.0.0.1\r\n' > "$D/config"
sh "$BIN/start.sh" >/dev/null; rc=$?
ok bad_config_rejected eq $rc 1
ok bad_config_reason has 'token missing'
ok bad_config_not_started eq "$(nagents)" 0
ok lock_released test ! -e "$PANEL_PID.lock"

begin t4
( sh "$BIN/start.sh" >/dev/null & sh "$BIN/start.sh" >/dev/null & wait )
ok concurrent_start_one_agent eq "$(nagents)" 1
sh "$BIN/stop.sh" >/dev/null

begin t5
echo 99999999 > "$PANEL_PID"
sh "$BIN/start.sh" >/dev/null
ok stale_dead_pid_replaced alive
sh "$BIN/stop.sh" >/dev/null
sleep 30 & other=$!
echo $other > "$PANEL_PID"
sh "$BIN/start.sh" >/dev/null
ok reused_pid_replaced sh -c "[ \"\$(cat '$PANEL_PID')\" != $other ] && kill -0 $other"
ok reused_pid_started has 'started'
kill $other 2>/dev/null
sh "$BIN/stop.sh" >/dev/null

begin t6
sh "$BIN/start.sh" >/dev/null
printf 'state=running\nlast_contact=%s\nlast_error=boom\n' "$(( $(date +%s) - 500 ))" > "$PANEL_STATUS"
sh "$BIN/status.sh" >/dev/null
ok status_stale has 'STALE'
ok status_error_text has 'error: boom'
sh "$BIN/stop.sh" >/dev/null

begin t7
sh "$BIN/show-config.sh" >/dev/null
ok show_config_plain_text has 'url=http://10.0.0.1:8123/api/x token=abc123 name=Kit'
begin t8 nocfg
sh "$BIN/show-config.sh" >/dev/null
ok show_config_missing has 'config.sample'

# deploy with ssh stub (extracts the tar into $D/dev, answers the config check)
begin t9
mkdir -p "$D/dev/dest"
cat > "$D/ssh" <<EOT
#!/bin/sh
case "\$2" in
  *"[ -f"*) [ -f "$D/dev/dest/config" ] ;;
  *) tar xf - -C "$D/dev/dest" ;;
esac
EOT
chmod +x "$D/ssh"
sh "$here/../deploy.sh" >/dev/null 2>&1; ok deploy_refuses_without_host test $? -ne 0
echo mine > "$D/dev/dest/config"
SSH="$D/ssh" sh "$here/../deploy.sh" devhost > "$D/out" 2>&1
ok deploy_copies_files test -f "$D/dev/dest/bin/start.sh" -a -f "$D/dev/dest/menu.json" -a -f "$D/dev/dest/config.sample"
ok deploy_keeps_config eq "$(cat "$D/dev/dest/config")" mine
ok deploy_reports grep -q 'config exists' "$D/out"

# menu.json / config.xml sanity
ok menu_json_valid python3 -m json.tool "$PKG/menu.json"
ok config_xml_valid python3 -c "import sys,xml.dom.minidom as m; m.parse(sys.argv[1])" "$PKG/config.xml"
for a in $(python3 -c "
import json,sys
def w(i):
    for x in i:
        if 'action' in x: print(x['action'])
        w(x.get('items',[]))
w(json.load(open(sys.argv[1]))['items'])" "$PKG/menu.json"); do
  ok "action_exists_$a" test -f "$PKG/$a"
done

[ $FAILS = 0 ] && echo "t_launcher: all ok" || echo "t_launcher: $FAILS failed"
[ $FAILS = 0 ]
