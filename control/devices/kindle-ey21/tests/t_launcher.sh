#!/bin/sh
# Launcher scripts with a stub eips and a fake agent (sleep loop).
here=$(cd "$(dirname "$0")" && pwd)
PKG="$here/../panel-control"; BIN="$PKG/bin"
T=$(mktemp -d); FAILS=0
cleanup() { rm -f "$PKG/display.on"; for p in $(cat "$T"/*/pid 2>/dev/null); do kill "$p" 2>/dev/null; done; pkill -f "$T/" 2>/dev/null; rm -rf "$T"; }
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
echo \$\$ > "\$PANEL_PID"
mkdir -p "\$PANEL_TMP"; echo secret > "\$PANEL_TMP/curl.cfg"
printf 'state=running\nlast_contact=%s\nlast_error=\nagent_version=t\n' "\$(date +%s)" > "\$PANEL_STATUS"
while :; do sleep 1; done
EOT
  unset FBINK; : > "$D/fbink.log"
  export PANEL_LOG="$D/panel.log" PANEL_DISPLAY_FLAG="$D/display.on"
  export PANEL_PID="$D/pid" PANEL_STATUS="$D/status" PANEL_TMP="$D/tmp" PANEL_CONFIG="$D/config" EIPS="$D/eips" AGENT="$D/bin/agent.sh"
  [ "$2" = nocfg ] || printf 'url = http://10.0.0.1:8123/api/x\r\ntoken = "abc123"\r\ndevice_name = Kit\r\n' > "$D/config"
}
fbstub() { # recording fbink stub for the primary path: one line per call, each argv in [ ]
  printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]" "$a"; done >> "%s"\necho >> "%s"\n' "$D/fbink.log" "$D/fbink.log" > "$D/fbink"
  chmod +x "$D/fbink"; export FBINK="$D/fbink"; }
fbhas() { grep -F -q -e "$1" "$D/fbink.log"; }
fbtext() { sed 's/^\[-q\]\[-p\]\[-y\]\[-*[0-9]*\]\[//; s/\]$//'; }
fbrow() { grep -F "[-y][$1][" "$D/fbink.log" | tail -n 1 | fbtext; }
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
ok status_prints_state_and_last_contact sh -c "grep -q 'state=running' '$D/eips.log' && grep -q 'last contact [0-9]* s ago' '$D/eips.log'"
ok status_not_stale sh -c "! grep -q STALE '$D/eips.log'"
kill_child_test=$(pgrep -P "$(cat "$PANEL_PID")" sleep | head -n 1)
ok child_existed_before_stop test -n "$kill_child_test"
ok child_alive_before_stop kill -0 "${kill_child_test:-99999999}"
sh "$BIN/stop.sh" >/dev/null; rc=$?
ok stop_kills_agent sh -c "! kill -0 $(cat "$D/pid" 2>/dev/null || echo 99999999) 2>/dev/null"
ok stop_removes_files sh -c "[ ! -e '$PANEL_PID' ] && [ ! -e '$PANEL_TMP' ] && [ ! -e '$PANEL_STATUS' ]"
ok stop_kills_children sh -c "! kill -0 ${kill_child_test:-99999999} 2>/dev/null && [ -n '$kill_child_test' ]"
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
ok say_pads_to_60 sh -c "awk '{ if (length(\$0) != 64) exit 1 }' '$D/eips.log'"
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
ok show_config_plain_text sh -c "grep -q 'url=http://10.0.0.1:8123/api/x' '$D/eips.log' && grep -q 'token=abc123' '$D/eips.log' && grep -q 'name=Kit' '$D/eips.log'"
begin t8 nocfg
sh "$BIN/show-config.sh" >/dev/null
ok show_config_missing has 'config.sample'

# deploy with ssh stub (extracts the tar into $D/dev, answers the config check)
begin t9
mkdir -p "$D/dev/dest"
cat > "$D/ssh" <<EOT
#!/bin/sh
case "\$3" in
  *"[ -f"*) echo check >> "$D/ssh.log"; [ -f "$D/dev/dest/config" ] ;;
  *) echo xfer >> "$D/ssh.log"; tar xf - -C "$D/dev/dest" ;;
esac
EOT
chmod +x "$D/ssh"
sh "$here/../deploy.sh" >/dev/null 2>&1; ok deploy_refuses_without_host test $? -ne 0
echo mine > "$D/dev/dest/config"
SSH="$D/ssh" sh "$here/../deploy.sh" devhost > "$D/out" 2>&1
ok deploy_copies_files test -f "$D/dev/dest/bin/start.sh" -a -f "$D/dev/dest/menu.json" -a -f "$D/dev/dest/config.sample"
ok deploy_keeps_config eq "$(cat "$D/dev/dest/config")" mine
ok deploy_reports grep -q 'config exists' "$D/out"

# foreign live process in the pid file must survive stop
begin t10
sleep 30 & other=$!
echo $other > "$PANEL_PID"
sh "$BIN/stop.sh" >/dev/null; rc=$?
ok stop_spares_foreign_process kill -0 $other
ok stop_foreign_not_running_msg has 'not running'
ok stop_foreign_removes_pidfile test ! -e "$PANEL_PID"
ok stop_foreign_rc eq $rc 0
kill $other 2>/dev/null

# deploy hardening
begin t11
mkdir -p "$D/dev/dest" "$D/sb"; printf '#!/bin/sh\nexit 1\n' > "$D/sb/tar"; chmod +x "$D/sb/tar"
cp "$T/t9/ssh" "$D/ssh"; sed -i "s|$T/t9|$D|g" "$D/ssh"
PATH="$D/sb:$PATH" SSH="$D/ssh" sh "$here/../deploy.sh" devhost >/dev/null 2>&1; rc=$?
ok deploy_tar_failure_nonzero test $rc -ne 0
ok deploy_tar_failure_no_transfer test ! -e "$D/ssh.log"
SSH="$D/ssh" sh "$here/../deploy.sh" -oProxyCommand=x >/dev/null 2>&1; rc=$?
ok deploy_refuses_dash_host test $rc -ne 0
ok deploy_dash_host_no_ssh test ! -e "$D/ssh.log"

# config.sample
ok sample_url_line sh -c "grep -q '^#.*url *= *http://[0-9.]*:[0-9]*/api/panel_control/[a-z0-9_]*\$' '$PKG/config.sample'"
. "$BIN/lib.sh"
sed 's/^#\(url\)/\1/; s/^#\(token\)/\1/' "$PKG/config.sample" > "$T/sample.cfg"
ok sample_loads sh -c ". '$BIN/lib.sh'; load_config '$T/sample.cfg'"

# is_agent with a real NUL-separated cmdline, started the way start.sh does
begin t12
mkdir -p "$D/real"; printf '#!/bin/sh\nwhile :; do sleep 1; done\n' > "$D/real/agent.sh"
sh "$D/real/agent.sh" >/dev/null 2>&1 & real=$!
sleep 30 & other=$!
isag() { sh -c '. "$1/launch-lib.sh"; is_agent "$2"' sh "$BIN" "$1"; }
ok is_agent_true_for_real_agent isag $real
ok is_agent_false_for_unrelated sh -c "! sh -c '. \"\$1/launch-lib.sh\"; is_agent \"\$2\"' sh '$BIN' $other"
kill $real $other 2>/dev/null

# stop kills a two-level process tree quickly
begin t15
cat > "$D/bin/agent.sh" <<'EOT'
#!/bin/sh
sleep 4242 &
sh -c 'sleep 4243 & wait' &
sh -c 'sh -c "sleep 4244" & wait' &
echo $$ > "$PANEL_PID"
mkdir -p "$PANEL_TMP"; printf 'state=running\nlast_contact=%s\n' "$(date +%s)" > "$PANEL_STATUS"
while :; do sleep 1; done
EOT
sh "$BIN/start.sh" >/dev/null; sleep 1
ok tree_exists_before eq "$(pgrep -f '^sleep 424' | wc -l)" 3
t0=$(date +%s); sh "$BIN/stop.sh" >/dev/null; t1=$(date +%s)
ok tree_all_killed eq "$(pgrep -f '^sleep 424' | wc -l)" 0
ok stop_fast test $((t1-t0)) -lt 3
ok tree_agent_gone eq "$(nagents)" 0

# stale rows are blanked, long messages wrap
begin t13
sh "$BIN/start.sh" >/dev/null
printf 'state=running\nlast_contact=%s\nlast_error=boom\n' "$(( $(date +%s) - 500 ))" > "$PANEL_STATUS"
sh "$BIN/status.sh" >/dev/null
sh "$BIN/stop.sh" >/dev/null
lastrow() { awk -v r="$1" '$2==r' "$D/eips.log" | tail -n 1 | cut -c5-; }
blank="$(printf '%60s' '')"
for r in 1 2 3 4; do ok "row_${r}_blank_after_stop" eq "$(lastrow $r)" "$blank"; done
begin t14
msg=$(printf '0123456789%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13)
sh -c '. "$1/launch-lib.sh"; say "$2"' sh "$BIN" "$msg" >/dev/null
got=$(tail -n 3 "$D/eips.log" | cut -c5- | sed 's/ *$//' | tr -d '\n')
ok long_message_wraps_no_loss eq "$got" "$msg"
ok long_message_rows sh -c "tail -n 3 '$D/eips.log' | cut -c3 | tr -d ' \n' | grep -q '^012\$'"
msg=$(printf '0123456789%.0s' $(seq 1 40))
sh -c '. "$1/launch-lib.sh"; say "$2"' sh "$BIN" "$msg" >/dev/null
ok overflow_ends_with_dots sh -c "tail -n 1 '$D/eips.log' | sed 's/ *\$//' | grep -q '\.\.\.\$'"

# ---- primary path: fbink on the bottom block (rows -10..-6), eips untouched
begin f1; fbstub
sh "$BIN/start.sh" >/dev/null
ok fb_start_shows_state fbhas '[-q][-p][-y][-10][Panel Control started: running]'
ok fb_first_say_blanks_five_rows eq "$(head -n 5 "$D/fbink.log" | tr -d '\n')" '[-q][-p][-y][-10][ ][-q][-p][-y][-9][ ][-q][-p][-y][-8][ ][-q][-p][-y][-7][ ][-q][-p][-y][-6][ ]'
ok fb_no_eips_when_fbink_present test ! -s "$D/eips.log"
ok fb_every_call_quiet_padded sh -c "! grep -v -F '[-q][-p][-y][-' '$D/fbink.log' | grep -q ."
sh "$BIN/start.sh" >/dev/null
ok fb_second_start_says_already_running fbhas 'already running'
sh "$BIN/status.sh" >/dev/null
ok fb_status_prints_state_and_last_contact sh -c "grep -q 'state=running' '$D/fbink.log' && grep -q 'last contact [0-9]* s ago' '$D/fbink.log'"
ok fb_status_not_stale sh -c "! grep -q STALE '$D/fbink.log'"
printf 'state=running\nlast_contact=%s\nlast_error=boom\n' "$(( $(date +%s) - 500 ))" > "$PANEL_STATUS"
sh "$BIN/status.sh" >/dev/null
ok fb_status_stale fbhas 'STALE'
ok fb_status_error_text fbhas 'error: boom'
sh "$BIN/stop.sh" >/dev/null
ok fb_stop_says_stopped fbhas 'Panel Control stopped'
for r in -9 -8 -7 -6; do ok "fb_row_${r}_blank_after_stop" eq "$(fbrow $r)" ' '; done
ok fb_no_eips_after_stop test ! -s "$D/eips.log"

begin f2 nocfg; fbstub
sh "$BIN/start.sh" >/dev/null; rc=$?
ok fb_no_config_rc eq $rc 1
ok fb_no_config_message fbhas 'config.sample'
begin f3; fbstub
sh "$BIN/show-config.sh" >/dev/null
ok fb_show_config_plain_text sh -c "grep -q 'url=http://10.0.0.1:8123/api/x' '$D/fbink.log' && grep -q 'token=abc123' '$D/fbink.log' && grep -q 'name=Kit' '$D/fbink.log'"

begin f4; fbstub
msg=$(printf '0123456789%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13)
sh -c '. "$1/launch-lib.sh"; say "$2"' sh "$BIN" "$msg" >/dev/null
got=$(tail -n 3 "$D/fbink.log" | fbtext | tr -d '\n')
ok fb_long_message_wraps_no_loss eq "$got" "$msg"
ok fb_long_message_rows eq "$(tail -n 3 "$D/fbink.log" | sed -n 's/.*\[-y\]\[\(-[0-9]*\)\].*/\1/p' | tr -d '\n')" '-10-9-8'
ok fb_wrap_width_46 eq "$(fbrow -10 | wc -c | tr -d ' ')" 47
begin f5; fbstub
msg=$(printf '0123456789%.0s' $(seq 1 40))
sh -c '. "$1/launch-lib.sh"; say "$2"' sh "$BIN" "$msg" >/dev/null
ok fb_overflow_ends_with_dots eq "$(fbrow -6 | sed 's/.*\(...\)$/\1/')" '...'
ok fb_overflow_fits_row eq "$(fbrow -6 | wc -c | tr -d ' ')" 47
ok fb_overflow_stays_in_block sh -c "! grep -F -q -e '[-y][-5][' -e '[-y][-11][' '$D/fbink.log'"
begin f6; fbstub
sh -c '. "$1/launch-lib.sh"; say "$2"' sh "$BIN" '%s %d \n %%' >/dev/null
ok fb_format_string_safe fbhas '[-y][-10][%s %d \n %%]'

# option safety: no text argument handed to fbink may start with '-' (it would be parsed as an option)
nodash() { ! fbtext < "$D/fbink.log" | grep -q '^-'; }
begin g1; fbstub
sh -c '. "$1/launch-lib.sh"; say "$2"' sh "$BIN" "$(printf 'x%.0s' $(seq 1 46))-abc" >/dev/null
ok fb_wrap_boundary_dash_not_option nodash
ok fb_wrap_boundary_dash_text_kept eq "$(fbrow -9)" ' -abc'
begin g2; fbstub
sh -c '. "$1/launch-lib.sh"; say "$2"' sh "$BIN" "$(printf 'x%.0s' $(seq 1 45))-abc-def" >/dev/null
ok fb_wrap_45_dash_not_option nodash
begin g3; fbstub
sh -c '. "$1/launch-lib.sh"; say "url=$2"' sh "$BIN" "$(printf 'a%.0s' $(seq 1 42))-tail-more" >/dev/null
ok fb_url_wrap_dash_not_option nodash
ok fb_url_wrap_text_kept eq "$(fbrow -9)" ' -tail-more'
begin g4; fbstub
sh -c '. "$1/launch-lib.sh"; say "$2"' sh "$BIN" "$(printf 'Maple-Orbit-Tiger-Quilt-Ember-%.0s' 1 2 3 4 5)" >/dev/null
ok fb_hyphen_passphrase_not_option nodash
begin g5; fbstub
sh -c '. "$1/launch-lib.sh"; say "-lonely"' sh "$BIN" >/dev/null
ok fb_leading_dash_message_not_option nodash

# ---- display toggle scripts and stop/start interplay (real device layer + fbink stub)
begin d1; fbstub
rm -f "$PANEL_STATUS"
sh "$BIN/display-on.sh" > "$D/out" 2>&1; rc=$?
ok on_rc eq $rc 0
ok on_creates_flag test -f "$PANEL_DISPLAY_FLAG"
ok on_silent test ! -s "$D/out"
ok on_not_running_line fbhas '[-q][-p][-y][-3][Panel Control: not running]'
: > "$D/fbink.log"; printf 'state=running\nlast_contact=1\n' > "$PANEL_STATUS"
sh "$BIN/display-on.sh" >/dev/null
ok on_stale_status_without_agent_is_not_running fbhas '[-q][-p][-y][-3][Panel Control: not running]'
rm -f "$PANEL_STATUS"; sh "$BIN/display-off.sh" >/dev/null
sh "$BIN/display-on.sh" >/dev/null
: > "$D/fbink.log"
sh "$BIN/start.sh" >/dev/null
printf '10:00:01 started\n10:00:02 hello ok (23 caps)\n10:00:03 cmd brightness ok\n' > "$PANEL_LOG"
printf 'state=running\nlast_contact=1\nlast_error=\n' > "$PANEL_STATUS"
: > "$D/fbink.log"
sh "$BIN/display-on.sh" >/dev/null
ok on_state_and_last_two_log_lines eq "$(cat "$D/fbink.log")" '[-q][-p][-y][-3][Panel Control: running]
[-q][-p][-y][-2][10:00:02 hello ok (23 caps)]
[-q][-p][-y][-1][10:00:03 cmd brightness ok]'
: > "$D/fbink.log"
printf '10:00:01 started\n' > "$PANEL_LOG"
sh "$BIN/display-on.sh" >/dev/null
ok on_single_log_line eq "$(sed -n 2,3p "$D/fbink.log" | tr -d '\n')" '[-q][-p][-y][-2][ ][-q][-p][-y][-1][10:00:01 started]'
sh "$BIN/stop.sh" >/dev/null
: > "$D/fbink.log"
sh "$BIN/display-off.sh" > "$D/out" 2>&1; rc=$?
ok off_rc eq $rc 0
ok off_removes_flag test ! -e "$PANEL_DISPLAY_FLAG"
ok off_silent test ! -s "$D/out"
ok off_clears_three_rows eq "$(cat "$D/fbink.log")" '[-q][-p][-y][-3][ ]
[-q][-p][-y][-2][ ]
[-q][-p][-y][-1][ ]'
: > "$D/fbink.log"
sh "$BIN/display-off.sh" >/dev/null
ok off_without_flag_does_not_draw test ! -s "$D/fbink.log"
begin d2   # no fbink anywhere: still silent, flag still managed
sh "$BIN/display-on.sh" > "$D/out" 2>&1; rc=$?
ok on_nofbink_silent_rc0 sh -c "[ $rc = 0 ] && [ ! -s '$D/out' ] && [ -f '$PANEL_DISPLAY_FLAG' ]"
sh "$BIN/display-off.sh" > "$D/out" 2>&1; rc=$?
ok off_nofbink_silent_rc0 sh -c "[ $rc = 0 ] && [ ! -s '$D/out' ] && [ ! -e '$PANEL_DISPLAY_FLAG' ]"

begin d3; fbstub
sh "$BIN/start.sh" >/dev/null
printf '10:00:01 started\n' > "$PANEL_LOG"; : > "$PANEL_DISPLAY_FLAG"; : > "$D/fbink.log"
sh "$BIN/stop.sh" >/dev/null
ok stop_draws_stopped_when_flag eq "$(grep -F -e '[-y][-3][' -e '[-y][-2][' -e '[-y][-1][' "$D/fbink.log" | tr -d '\n')" '[-q][-p][-y][-3][Panel Control: stopped][-q][-p][-y][-2][ ][-q][-p][-y][-1][ ]'
ok stop_removes_log test ! -e "$PANEL_LOG"
ok stop_keeps_flag test -f "$PANEL_DISPLAY_FLAG"
begin d4; fbstub
sh "$BIN/start.sh" >/dev/null; : > "$D/fbink.log"
sh "$BIN/stop.sh" >/dev/null
ok stop_without_flag_no_display_rows sh -c "! grep -F -q -e '[-y][-3][' -e '[-y][-2][' -e '[-y][-1][' '$D/fbink.log'"
begin d5
printf 'old\n' > "$PANEL_LOG"
sh "$BIN/start.sh" >/dev/null
ok start_wipes_log test ! -e "$PANEL_LOG"
ok start_exports_log_path sh -c "grep -q . '$PANEL_PID'"
sh "$BIN/stop.sh" >/dev/null

# deploy never ships display.on (device state)
begin d6
mkdir -p "$D/dev/dest"; cp "$T/t9/ssh" "$D/ssh"; sed -i "s|$T/t9|$D|g" "$D/ssh"
: > "$PKG/display.on"
SSH="$D/ssh" sh "$here/../deploy.sh" devhost >/dev/null 2>&1
rm -f "$PKG/display.on"
ok deploy_copies_files_again test -f "$D/dev/dest/bin/display-on.sh" -a -f "$D/dev/dest/bin/display-off.sh"
ok deploy_never_ships_display_flag test ! -e "$D/dev/dest/display.on"
: > "$D/dev/dest/display.on"
SSH="$D/ssh" sh "$here/../deploy.sh" devhost >/dev/null 2>&1
ok deploy_keeps_device_display_flag test -f "$D/dev/dest/display.on"

ok menu_order eq "$(python3 -c "
import json,sys
print('|'.join(x['name']+'='+x['action'] for x in sorted(json.load(open(sys.argv[1]))['items'][0]['items'],key=lambda x:x['priority'])))" "$PKG/menu.json")" 'Start=bin/start.sh|Stop=bin/stop.sh|Status=bin/status.sh|Status on screen: ON=bin/display-on.sh|Status on screen: OFF=bin/display-off.sh|Show config=bin/show-config.sh'

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
