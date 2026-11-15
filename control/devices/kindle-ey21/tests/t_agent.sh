#!/bin/sh
# Agent loop against mock_ha.py. Needs python3 with jsonschema (PATH=control/.venv/bin:$PATH).
here=$(cd "$(dirname "$0")" && pwd)
AGENT="$here/../panel-control/bin/agent.sh"
T=$(mktemp -d); MOCK_PID=; AGENT_PID=
FAILS=0; N=0
kill_tree() { for _c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$_c"; done; kill "$1" 2>/dev/null; }
kill_agent() { [ -n "$AGENT_PID" ] || return 0; kill -STOP "$AGENT_PID" 2>/dev/null; kill_tree "$AGENT_PID"; kill -CONT "$AGENT_PID" 2>/dev/null; }
cleanup() { kill_agent; [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
check() { N=$((N+1)); _n=$1; shift; if ! "$@" >/dev/null 2>&1; then FAILS=$((FAILS+1)); echo "FAIL $_n"; [ -f "$LOG" ] && sed 's/^/    log: /' "$LOG" | head -20; fi; }
cnt() { grep -c -e "$1" "$LOG" 2>/dev/null || true; }
has() { grep -q -e "$1" "$LOG"; }
hasnt() { ! grep -q -e "$1" "$LOG"; }
ge() { [ "$1" -ge "$2" ]; }
eq() { [ "$1" = "$2" ]; }
statusHas() { grep -q -e "$1" "$STATUS"; }
wait_for() { # <grep pattern in $LOG> <secs>
  _i=0; while [ $_i -lt $(($2*10)) ]; do grep -q -e "$1" "$LOG" 2>/dev/null && return 0; sleep 0.1; _i=$((_i+1)); done; return 1; }
wait_status() { _i=0; while [ $_i -lt $(($2*10)) ]; do grep -q -e "$1" "$STATUS" 2>/dev/null && return 0; sleep 0.1; _i=$((_i+1)); done; return 1; }

# pieces for scenarios
H() { printf '{"contract":1,"heartbeat_s":2,"poll_wait_s":1,"config":{"config_rev":%s,"enabled":[%s],"interval_s":{%s}}}' "$1" "$2" "$3"; }
OKSTATE='{"status":200,"body":{"config_rev":1}}'
NOCMD='{"status":200,"body":{"config_rev":1,"commands":[]}}'
mk() { # <hello-entries> [state-entries] [commands-entries] [config-entries]
  printf '{"hello":[%s],"state":[%s],"commands":[%s],"config":[%s]}' "$1" "${2:-$OKSTATE}" "${3:-$NOCMD}" "${4:-{\}}" > "$D/scen.json"; }
helloE() { printf '{"status":200,"body":%s}' "$(H "$@")"; }

begin() { # <name>: new case dir, exports env for the agent
  D="$T/$1"; mkdir -p "$D/fake"; LOG="$D/log"; STATUS="$D/status"; : > "$LOG"
  export FAKE_DIR="$D/fake" PANEL_STATUS="$STATUS" PANEL_TMP="$D/tmp" PANEL_CONFIG="$D/config" \
    PANEL_LOG="$D/panel.log" PANEL_DISPLAY_FLAG="$D/display.on" PANEL_DISPLAY_MIN=1 \
    DEVICE_LAYER="$here/fake_device.sh" PANEL_BACKOFF_BASE=1 PANEL_LOCKOUT_WAIT=2 PANEL_AUTH_WAIT=30
  unset FAKE_FAIL_GET
}
start_mock() {
  python3 "$here/mock_ha.py" "$D/scen.json" "$D/port" "$LOG" >"$D/mock.out" 2>&1 & MOCK_PID=$!
  _i=0; while [ ! -f "$D/port" ] && [ $_i -lt 50 ]; do sleep 0.1; _i=$((_i+1)); done
  PORT=$(cat "$D/port")
}
write_cfg() { printf 'url = http://127.0.0.1:%s/api/panel_control/k/\ntoken = Maple-Orbit-Tiger-Quilt-Ember\n%s' "$PORT" "$1" > "$PANEL_CONFIG"; }
start_agent() { sh "$AGENT" >"$D/agent.out" 2>&1 & AGENT_PID=$!; }
stop_all() {
  kill_agent; [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
  wait 2>/dev/null; AGENT_PID=; MOCK_PID=; }
run() { start_mock; write_cfg "$1"; start_agent; }  # <extra config lines>
alive() { kill -0 "$AGENT_PID" 2>/dev/null; }
before() { # line number of first match
  grep -n -e "$1" "$LOG" | head -n 1 | cut -d: -f1; }
lt() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]; }

test_hello_then_state() {
  begin hello_state; mk "$(helloE 1 '"brightness"')"; run
  wait_for '^POST .*/state ' 6; wait_for '^GET .*/commands?wait=' 3
  check hello_first eq "$(head -n 1 "$LOG" | cut -c1-4)" POST
  check hello_path has '^POST /api/panel_control/k/hello auth=Bearer Maple-Orbit-Tiger-Quilt-Ember body='
  check hello_before_state lt "$(before '/hello ')" "$(before '/state ')"
  check status_running statusHas '^state=running'
  check status_version statusHas '^agent_version=0.1.0'
  check status_contact statusHas '^last_contact=[0-9]'
  check commands_after_state has '^GET /api/panel_control/k/commands?wait='
  stop_all
}
test_hello_body_has_catalog_ids_only_and_no_warmth() {
  begin hello_body; mk "$(helloE 1 '"brightness"')"; run; wait_for '/hello ' 5
  check hello_ids has 'body={"contract":1,"agent_version":"0.1.0","device":{"name":"FakeKindle".*"capabilities":\[{"id":"brightness"},{"id":"battery_level"},{"id":"cpu_load"},{"id":"refresh_screen"},{"id":"clock_offset"}\]}'
  check no_warmth hasnt warmth
  check no_serial hasnt serial_number
  stop_all
}
test_state_only_enabled_ids() {
  begin only_enabled; mk "$(helloE 1 '"brightness"')"; run; wait_for '/state ' 6
  check only_brightness has '/state .*"values":{"brightness":10}'
  check no_battery hasnt '/state .*battery_level'
  check no_cpu hasnt '/state .*cpu_load'
  stop_all
}
test_state_includes_time_and_not_virtual_or_write_only() {
  begin time_virtual; mk "$(helloE 1 '"brightness","battery_level","cpu_load","refresh_screen","clock_offset"')"; run; wait_for '/state .*battery_level' 6
  check has_time has '/state .*body={"time":[0-9]\{9,\},"values":{'
  check no_clock_offset hasnt '/state .*clock_offset'
  check no_refresh hasnt '/state .*refresh_screen'
  stop_all
}
test_interval_respected() {
  begin interval; mk "$(helloE 1 '"cpu_load"' '"cpu_load":60')"; run; wait_for '/state .*cpu_load' 6
  sleep 4
  check once eq "$(cnt '/state .*cpu_load')" 1
  check heartbeats ge "$(cnt 'POST .*/state ')" 2
  stop_all
}
test_command_applied_and_acked() {
  begin cmd_ok; mk "$(helloE 1 '"brightness"')" "" \
    '{"status":200,"body":{"config_rev":1,"commands":[{"id":"c1","capability":"brightness","value":40,"issued_at":1763200000}]}},'"$NOCMD"
  run; wait_for '"acks":\[{"id":"c1","ok":true}\]' 8
  check set_called grep -q '^brightness 40$' "$FAKE_DIR/set.log"
  check ack_state has '/state .*"values":{"brightness":40},"acks":\[{"id":"c1","ok":true}\]'
  stop_all
}
test_undeclared_command_acked_not_ok() {
  begin cmd_bad; mk "$(helloE 1 '"brightness"')" "" \
    '{"status":200,"body":{"config_rev":1,"commands":[{"id":"c1","capability":"warmth","value":5,"issued_at":1763200000}]}},'"$NOCMD"
  run; wait_for '"acks":\[{"id":"c1","ok":false,"error":"' 8
  check not_ok has '"acks":\[{"id":"c1","ok":false,"error":"[^"]\+"}\]'
  check no_set eq "$(cat "$FAKE_DIR/set.log" 2>/dev/null | wc -l | tr -d ' ')" 0
  stop_all
}
test_dev_get_failure_sends_null() {
  begin get_fail; mk "$(helloE 1 '"battery_level","brightness"')"; export FAKE_FAIL_GET=battery_level; run
  wait_for '/state ' 6
  check null_sent has '/state .*"battery_level":null'
  check others_ok has '/state .*"brightness":10'
  check alive alive
  stop_all
}
test_config_rev_change_fetches_config() {
  begin cfg_rev; mk "$(helloE 1 '"brightness"')" '{"status":200,"body":{"config_rev":2}}' "" \
    '{"status":200,"body":{"config_rev":2,"enabled":["battery_level"],"interval_s":{}}}'
  run; wait_for '/state .*"battery_level":80' 8
  check config_fetched has '^GET /api/panel_control/k/config '
  check new_set has '/state .*"battery_level":80'
  stop_all
}
test_409_triggers_new_hello() {
  begin conflict; mk "$(helloE 1 '"brightness"')" '{"status":409,"body":{"error":"hello_required"}},'"$OKSTATE"; run
  _i=0; while [ "$(cnt '/hello ')" -lt 2 ] && [ $_i -lt 80 ]; do sleep 0.1; _i=$((_i+1)); done
  check second_hello ge "$(cnt '/hello ')" 2
  stop_all
}
test_html_error_body_backoff_no_crash() {
  begin html502; E='{"status":502,"body":"<html>bad gateway</html>"}'; mk "$E" "$E" "$E" "$E"; run
  wait_status '^state=backoff' 6
  check backoff statusHas '^state=backoff'
  sleep 2
  check alive alive
  check retried ge "$(cnt '/hello ')" 2
  stop_all
}
test_unreachable_server_backoff() {
  begin unreachable; PORT=1; write_cfg ""; start_agent
  wait_status '^state=backoff' 8
  check backoff statusHas '^state=backoff'
  check has_error statusHas '^last_error=.\+'
  check alive alive
  stop_all
}
test_401_sets_error_status() {
  begin auth401; mk '{"status":401,"body":{"error":"unauthorized"}}'; run
  wait_status '^state=error' 6
  check error statusHas '^state=error'
  check alive alive
  stop_all
}
test_bad_config_exit_2() {
  begin badcfg; printf 'url = http://x\n' > "$PANEL_CONFIG"
  sh "$AGENT" >"$D/agent.out" 2>&1; rc=$?
  check exit2 eq "$rc" 2
  check error_status statusHas '^state=error'
  check reason statusHas '^last_error=.*token'
}
test_429_waits() {
  begin lock429; mk '{"status":429,"body":{"error":"locked_out"}},'"$(helloE 1 '"brightness"')"; run
  sleep 1
  check one_hello eq "$(cnt '/hello ')" 1
  wait_for '/state ' 8
  check recovered ge "$(cnt '/state ')" 1
  stop_all
}
test_poll_wait_never_zero() {
  # interval 1 s but the state post takes 1.5 s: the unclamped wait would be <= 0
  begin wait_min; mk '{"status":200,"body":{"contract":1,"heartbeat_s":60,"poll_wait_s":25,"config":{"config_rev":1,"enabled":["cpu_load"],"interval_s":{"cpu_load":1}}}}' \
    '{"status":200,"delay":1.5,"body":{"config_rev":1}}'; run
  _i=0; while [ "$(cnt 'GET .*commands?')" -lt 2 ] && [ $_i -lt 80 ]; do sleep 0.1; _i=$((_i+1)); done
  check polled ge "$(cnt 'GET .*commands?')" 2
  check first_wait_is_1 has '^GET [^ ]*commands?wait=1 '
  check no_zero_or_neg hasnt 'commands?wait=\(0\|-\)'
  stop_all
}
test_serial_only_with_opt_in() {
  begin serial_no; mk "$(helloE 1 '"brightness"')"; run ""; wait_for '/hello ' 5
  check no_serial hasnt 'B0TESTSERIAL'; stop_all
  begin serial_yes; mk "$(helloE 1 '"brightness"')"; run "send_serial = 1
"; wait_for '/hello ' 5
  check serial has 'B0TESTSERIAL'; stop_all
}
test_crlf_config() {
  begin crlf; mk "$(helloE 1 '"brightness"')"; start_mock
  printf '\357\273\277# c\r\nurl = http://127.0.0.1:%s/api/panel_control/k\r\ntoken = Maple-Orbit-Tiger-Quilt-Ember\r\n' "$PORT" > "$PANEL_CONFIG"
  start_agent; wait_for '/state ' 6
  check crlf_state has '^POST .*/state auth=Bearer Maple-Orbit-Tiger-Quilt-Ember body='
  stop_all
}
test_command_forces_reread() {
  begin cmd_same; mk "$(helloE 1 '"brightness"')" "" \
    '{"status":200,"body":{"config_rev":1,"commands":[{"id":"c2","capability":"brightness","value":10,"issued_at":1763200000}]}},'"$NOCMD"
  run; wait_for '"acks":\[{"id":"c2","ok":true}\]' 8
  check set_called grep -q '^brightness 10$' "$FAKE_DIR/set.log"
  check value_sent_with_ack has '/state .*"values":{"brightness":10},"acks":\[{"id":"c2","ok":true}\]'
  stop_all
}
test_command_with_new_config_rev_not_lost() {
  begin cmd_rev; mk "$(helloE 1 '"brightness"')" '{"status":200,"body":{"config_rev":1}},{"status":200,"body":{"config_rev":2}}' \
    '{"status":200,"body":{"config_rev":2,"commands":[{"id":"c1","capability":"brightness","value":40,"issued_at":1763200000}]}},{"status":200,"body":{"config_rev":2,"commands":[]}}' \
    '{"status":200,"body":{"config_rev":2,"enabled":["brightness","battery_level"],"interval_s":{}}}'
  run; wait_for '"acks":\[{"id":"c1","ok":true}\]' 8
  check applied grep -q '^brightness 40$' "$FAKE_DIR/set.log"
  check acked has '/state .*"acks":\[{"id":"c1","ok":true}\]'
  check config_fetched has '^GET /api/panel_control/k/config '
  wait_for '/state .*"battery_level":80' 6
  check new_config_used has '/state .*"battery_level":80'
  stop_all
}
test_no_tight_loop_on_junk_200() {
  _k=0; for _b in '{}' '<html>portal</html>' '' ; do
    _k=$((_k+1)); begin junk$_k; E="{\"status\":200,\"body\":$(printf '%s' "$_b" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}"
    mk "$(helloE 1 '"brightness"')" "$OKSTATE" "$E"; run; sleep 4
    check "junk_bounded[$_b]" ge 12 "$(cnt 'GET .*commands?')"
    check "junk_alive[$_b]" alive
    stop_all
  done
  begin instant; mk "$(helloE 1 '"brightness"')" "$OKSTATE" '{"status":200,"delay":0,"body":{"config_rev":1,"commands":[]}}'; run; sleep 4
  check instant_bounded ge 8 "$(cnt 'GET .*commands?')"
  stop_all
}
test_409_always_not_tight() {
  begin always409; mk "$(helloE 1 '"brightness"')" '{"status":409,"body":{"error":"hello_required"}}'; run; sleep 5
  check bounded ge 12 "$(( $(cnt '/hello ') + $(cnt '/state ') ))"
  check rehello ge "$(cnt '/hello ')" 2
  stop_all
}
mk_date_stub() { # <mode: back|empty>: from the 10th call on, date +%s is 1000 s earlier / empty
  mkdir -p "$D/bin"
  cat > "$D/bin/date" <<EOS
#!/bin/sh
f="$D/dn"; n=\$(cat \$f 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > \$f
r=\$(/bin/date +%s)
if [ \$n -ge 10 ]; then case "$1" in empty) echo ;; *) echo \$((r-1000)) ;; esac; else echo \$r; fi
EOS
  chmod +x "$D/bin/date"
}
run_stub() { start_mock; write_cfg ""; _p=$PATH; PATH="$D/bin:$PATH"; start_agent; PATH=$_p; }
test_clock_jump_back_does_not_stall() {
  begin clock_back; mk "$(helloE 1 '"brightness"')"; mk_date_stub back; run_stub; sleep 7
  check heartbeats_continue ge "$(cnt 'POST .*/state ')" 3
  stop_all
}
test_bad_clock_no_crash() {
  begin clock_empty; mk "$(helloE 1 '"brightness"')"; mk_date_stub empty; run_stub; sleep 4
  check alive alive
  stop_all
}
test_token_with_quote_and_backslash_exact() {
  begin tokesc; mk "$(helloE 1 '"brightness"')"; start_mock
  printf 'url = http://127.0.0.1:%s/api/panel_control/k/\ntoken = a"b\\c\n' "$PORT" > "$PANEL_CONFIG"
  start_agent; wait_for '/hello ' 5
  check token_exact grep -F -q 'auth=Bearer a"b\c body=' "$LOG"
  stop_all
}
test_second_instance_is_not_this_task() { echo "SKIP second_instance (launcher, Task 4)"; }

plog_has() { grep -q -e "$1" "$PANEL_LOG"; }
plog_hasnt() { ! grep -q -e "$1" "$PANEL_LOG" 2>/dev/null; }
disp_cnt() { grep -c "^DRAW" "$FAKE_DIR/disp.log" 2>/dev/null || true; }
test_event_log_content() {
  begin evlog; mk "$(helloE 1 '"brightness"')" "" \
    '{"status":200,"body":{"config_rev":1,"commands":[{"id":"c1","capability":"brightness","value":40,"issued_at":1763200000},{"id":"c2","capability":"warmth","value":5,"issued_at":1763200000}]}},'"$NOCMD"
  run; wait_for '/state .*"acks":\[{"id":"c1"' 8; sleep 3
  check log_started plog_has '^[0-9][0-9]:[0-9][0-9]:[0-9][0-9] started$'
  check log_hello plog_has ' hello ok (5 caps)$'
  check log_cmd_ok plog_has ' cmd brightness ok$'
  check log_cmd_failed plog_has ' cmd warmth FAILED: capability not declared$'
  check log_no_online_on_clean_run plog_hasnt ' online$'
  check log_not_spammed ge 8 "$(wc -l < "$PANEL_LOG" | tr -d ' ')"
  for _s in Maple B0TESTSERIAL aa:bb 'token' 127.0.0.1 '"value"'; do check "log_no_secret_$_s" plog_hasnt "$_s"; done
  stop_all
}
test_event_log_failure_then_online() {
  begin evfail; mk '{"status":500,"body":"x"},'"$(helloE 1 '"brightness"')"; run; wait_for '/state ' 8; sleep 1
  check log_http_500 plog_has ' http 500, retry in 1s$'
  check log_online plog_has ' online$'
  check log_online_after_failure lt "$(grep -n 'http 500' "$PANEL_LOG" | head -n 1 | cut -d: -f1)" "$(grep -n ' online$' "$PANEL_LOG" | head -n 1 | cut -d: -f1)"
  check log_online_once eq "$(grep -c ' online$' "$PANEL_LOG")" 1
  stop_all
}
test_event_log_unreachable_401_429_409() {
  begin evunr; PORT=1; write_cfg ""; start_agent; sleep 2
  check log_unreachable plog_has ' HA unreachable, retry in 1s$'
  stop_all
  begin ev401; mk '{"status":401,"body":{"error":"unauthorized"}}'; run; sleep 2
  check log_401 plog_has ' unauthorized (check token)$'
  check log_401_once eq "$(grep -c unauthorized "$PANEL_LOG")" 1
  stop_all
  begin ev429; mk '{"status":429,"body":{"error":"locked_out"}},'"$(helloE 1 '"brightness"')"; run; sleep 1
  check log_429 plog_has ' locked out, wait 2s$'
  stop_all
  begin ev409; mk "$(helloE 1 '"brightness"')" '{"status":409,"body":{"error":"hello_required"}},'"$OKSTATE"; run; sleep 3
  check log_409 plog_has ' 409 re-hello$'
  stop_all
}
test_event_log_bounded() {
  begin evbound; _i=0; while [ $_i -lt 60 ]; do echo "00:00:00 old $_i" >> "$PANEL_LOG"; _i=$((_i+1)); done
  mk "$(helloE 1 '"brightness"')"; run; wait_for '/state ' 6; sleep 1
  check log_trimmed ge 45 "$(wc -l < "$PANEL_LOG" | tr -d ' ')"
  check log_keeps_recent plog_has ' hello ok'
  check log_keeps_tail_of_old plog_has 'old 59$'
  check log_drops_head_of_old plog_hasnt 'old 0$'
  check log_no_tmp_left test ! -e "$PANEL_LOG.tmp"
  stop_all
}
test_display_inert_without_flag() {
  begin disp_off; mk "$(helloE 1 '"brightness"')"; run; sleep 4
  check no_draw test ! -s "$FAKE_DIR/disp.log"
  check alive_without_flag alive
  stop_all
}
wait_disp() { # <grep pattern in disp.log> <secs>
  _i=0; while [ $_i -lt $(($2*10)) ]; do grep -q -e "$1" "$FAKE_DIR/disp.log" 2>/dev/null && return 0; sleep 0.1; _i=$((_i+1)); done; return 1; }
test_display_draws_coalesces_and_clears() {
  begin disp_on; : > "$D/display.on"; export PANEL_DISPLAY_MIN=4
  mk "$(helloE 1 '"brightness"')"; run; wait_for '/hello ' 5; sleep 1
  check first_draw_only eq "$(disp_cnt)" 1
  check first_draw_line1 grep -q '^DRAW Panel Control: backoff no contact yet|' "$FAKE_DIR/disp.log"
  wait_disp '^DRAW Panel Control: running [0-9][0-9]:[0-9][0-9]:[0-9][0-9]|.* started|[0-9:]* hello ok (5 caps)$' 8
  check second_draw_running grep -q '^DRAW Panel Control: running [0-9][0-9]:[0-9][0-9]:[0-9][0-9]|.* started|[0-9:]* hello ok (5 caps)$' "$FAKE_DIR/disp.log"
  check exactly_two_draws eq "$(disp_cnt)" 2
  sleep 6
  check no_redraw_on_heartbeats eq "$(disp_cnt)" 2
  check no_secret_on_display sh -c "! grep -q -e Maple -e B0TESTSERIAL -e aa:bb '$FAKE_DIR/disp.log'"
  rm -f "$D/display.on"; wait_disp '^CLEAR' 6
  check cleared_once eq "$(grep -c '^CLEAR' "$FAKE_DIR/disp.log")" 1
  sleep 3
  check cleared_only_once eq "$(grep -c '^CLEAR' "$FAKE_DIR/disp.log")" 1
  check alive_after_clear alive
  export PANEL_DISPLAY_MIN=1
  stop_all
}
test_display_shows_error_state_immediately() {
  # the 401 branch sleeps AUTH_WAIT (30 s here): the screen must not keep showing the old state meanwhile
  begin disp_401; : > "$D/display.on"; export PANEL_DISPLAY_MIN=3
  mk '{"status":401,"body":{"error":"unauthorized"}}'; run; sleep 1
  check rate_limited_one_draw eq "$(disp_cnt)" 1
  wait_disp '^DRAW Panel Control: error no contact yet|.*unauthorized (check token)$' 6
  check error_drawn_long_before_auth_wait grep -q '^DRAW Panel Control: error no contact yet|.*unauthorized (check token)$' "$FAKE_DIR/disp.log"
  check at_most_one_draw_per_min eq "$(disp_cnt)" 2
  check alive_in_wait alive
  export PANEL_DISPLAY_MIN=1
  stop_all
}
test_display_shows_backoff_state() {
  begin disp_502; : > "$D/display.on"
  mk '{"status":502,"body":"x"}'; run
  wait_disp '^DRAW Panel Control: backoff no contact yet|.*http 502, retry in' 8
  check backoff_drawn grep -q '^DRAW Panel Control: backoff no contact yet|.*http 502, retry in' "$FAKE_DIR/disp.log"
  stop_all
}
test_display_shows_error_on_bad_config() {
  begin disp_badcfg; : > "$D/display.on"; printf 'url = http://x\n' > "$PANEL_CONFIG"
  sh "$AGENT" >"$D/agent.out" 2>&1; rc=$?
  check exit2_with_display eq "$rc" 2
  check bad_config_error_drawn eq "$(grep -c '^DRAW Panel Control: error ' "$FAKE_DIR/disp.log")" 1
}
test_display_min_invalid_uses_default() {
  begin disp_minbad; : > "$D/display.on"; export PANEL_DISPLAY_MIN=abc
  mk "$(helloE 1 '"brightness"')"; run; wait_for '/state ' 6; sleep 3
  check invalid_min_coalesces eq "$(disp_cnt)" 1
  check alive alive
  export PANEL_DISPLAY_MIN=1
  stop_all
}
test_display_survives_clock_jump_back() {
  begin disp_clock; : > "$D/display.on"; mk "$(helloE 1 '"brightness"')"; mk_date_stub back; run_stub; sleep 6
  _i=0; while [ $_i -lt 4 ]; do _i=$((_i+1)); echo "00:00:0$_i tst$_i" >> "$PANEL_LOG"; sleep 2; done
  check redraw_after_jump wait_disp 'tst[34]' 6
  stop_all
}
test_event_log_exact_bounds() {
  # hello is delayed so the log can be inspected at exactly 60 lines (59 seeded + started), then it becomes 61 and is trimmed
  begin evexact; _i=0; while [ $_i -lt 59 ]; do echo "00:00:00 old $_i" >> "$PANEL_LOG"; _i=$((_i+1)); done
  mk '{"status":200,"delay":3,"body":'"$(H 1 '"brightness"' '')"'}'; run; sleep 1
  check sixty_not_rotated eq "$(wc -l < "$PANEL_LOG" | tr -d ' ')" 60
  check sixty_keeps_head plog_has 'old 0$'
  wait_for '/state ' 8; sleep 1
  check sixtyone_rotated ge 42 "$(wc -l < "$PANEL_LOG" | tr -d ' ')"
  check sixtyone_head_gone plog_hasnt 'old 0$'
  stop_all
}
for t in hello_then_state hello_body_has_catalog_ids_only_and_no_warmth state_only_enabled_ids \
  state_includes_time_and_not_virtual_or_write_only interval_respected command_applied_and_acked \
  undeclared_command_acked_not_ok dev_get_failure_sends_null config_rev_change_fetches_config \
  409_triggers_new_hello html_error_body_backoff_no_crash unreachable_server_backoff 401_sets_error_status \
  command_forces_reread command_with_new_config_rev_not_lost no_tight_loop_on_junk_200 409_always_not_tight \
  token_with_quote_and_backslash_exact clock_jump_back_does_not_stall bad_clock_no_crash bad_config_exit_2 429_waits poll_wait_never_zero serial_only_with_opt_in crlf_config second_instance_is_not_this_task \
  event_log_content event_log_failure_then_online event_log_unreachable_401_429_409 event_log_bounded \
  display_inert_without_flag display_draws_coalesces_and_clears display_shows_error_state_immediately \
  display_shows_backoff_state display_shows_error_on_bad_config display_min_invalid_uses_default \
  display_survives_clock_jump_back event_log_exact_bounds; do
  "test_$t"
done
check no_schema_errors sh -c "! grep -r -e '-ERROR' $T --include=log"
echo "t_agent: $N checks, $FAILS failed"
[ $FAILS = 0 ]
