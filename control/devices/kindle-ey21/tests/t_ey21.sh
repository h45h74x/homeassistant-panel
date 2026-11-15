#!/bin/sh
# EY21 device layer tests: stubs + fixtures, no device. Integration at the end needs python3 + jsonschema.
here=$(cd "$(dirname "$0")" && pwd)
LAYER="$here/../panel-control/bin/ey21.sh"
T=$(mktemp -d); MOCK_PID=; AGENT_PID=
FAILS=0; N=0
kill_tree() { for _c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$_c"; done; kill "$1" 2>/dev/null; }
cleanup() { [ -n "$AGENT_PID" ] && { kill -STOP "$AGENT_PID" 2>/dev/null; kill_tree "$AGENT_PID"; kill -CONT "$AGENT_PID" 2>/dev/null; }
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null; rm -rf "${T:?}"; }
trap cleanup EXIT
ok() { N=$((N+1)); [ "$2" = "$3" ] || { FAILS=$((FAILS+1)); echo "FAIL $1: expected [$2] got [$3]"; }; }
yes_() { N=$((N+1)); _n=$1; shift; "$@" >/dev/null 2>&1 || { FAILS=$((FAILS+1)); echo "FAIL $_n"; }; }
no_() { N=$((N+1)); _n=$1; shift; if "$@" >/dev/null 2>&1; then FAILS=$((FAILS+1)); echo "FAIL $_n (expected failure)"; fi; }
BASEPATH=$PATH
fx() { # fresh fixture copy + env for a test
  rm -rf "${T:?}/fx" "${T:?}/tmp"; cp -r "$here/fixtures" "$T/fx"; : > "$T/log"; mkdir -p "$T/tmp"
  export PROC_ROOT="$T/fx/proc" SYS_ROOT="$T/fx/sys" ETC_ROOT="$T/fx/etc" EIPS="$here/stubs/bin/eips" \
    STUB_LIPC="$T/fx/lipc" STUB_DF="$T/fx/df" STUB_IFCONFIG="$T/fx/ifconfig" STUB_LOG="$T/log" PANEL_TMP="$T/tmp"
  CFG_SERIAL=0; export CFG_SERIAL
  unset STUB_UNAME STUB_HOSTNAME
  PATH="$here/stubs/bin:$BASEPATH"
}
. "$LAYER"
get() { dev_get "$1" 2>/dev/null; }
lp() { printf '%s\n' "$2" > "$STUB_LIPC/com.lab126.powerd.$1"; }
has() { printf '%s\n' "$1" | grep -qx -e "$2"; }

test_brightness_get_rounds() { fx; ok bright_3 13 "$(get brightness)"; lp flIntensity 24; ok bright_24 100 "$(get brightness)"; lp flIntensity 0; ok bright_0 0 "$(get brightness)"; }
test_brightness_set() {
  fx; dev_set brightness 50 >/dev/null; ok set50 "lipc-set-prop com.lab126.powerd flIntensity 12" "$(cat "$STUB_LOG")"
  fx; dev_set brightness 250 >/dev/null; ok set250 "lipc-set-prop com.lab126.powerd flIntensity 24" "$(cat "$STUB_LOG")"
  fx; dev_set brightness -5 >/dev/null; ok setneg "lipc-set-prop com.lab126.powerd flIntensity 0" "$(cat "$STUB_LOG")"
  fx; _m=$(dev_set brightness abc); _rc=$?; yes_ setabc_rc test $_rc -ne 0; ok setabc_nocall "" "$(cat "$STUB_LOG")"; yes_ setabc_reason test -n "$_m"
}
test_battery_and_charging() { fx; ok batt 88 "$(get battery_level)"; ok chg0 false "$(get charging)"; lp isCharging 1; ok chg1 true "$(get charging)"; }
test_power_state_mapping() {
  fx; for p in "active:active" "screenSaver:screensaver" "readyToSuspend:screensaver"; do lp state "${p%%:*}"; ok "ps_${p%%:*}" "${p##*:}" "$(get power_state)"; done
  lp state weird; no_ ps_other dev_get power_state
}
test_frontlight_on() { fx; ok fl_on true "$(get frontlight_on)"; lp flIntensity 0; ok fl_off false "$(get frontlight_on)"; }
test_keep_awake_get_set() {
  fx; ok ka0 false "$(get keep_awake)"; lp preventScreenSaver 1; ok ka1 true "$(get keep_awake)"
  fx; dev_set keep_awake true >/dev/null; dev_set keep_awake false >/dev/null
  ok ka_set "lipc-set-prop com.lab126.powerd preventScreenSaver 1
lipc-set-prop com.lab126.powerd preventScreenSaver 0" "$(cat "$STUB_LOG")"
}
test_refresh_screen_set() { fx; dev_set refresh_screen press >/dev/null; ok eips "eips -c" "$(cat "$STUB_LOG")"; no_ refresh_read dev_get refresh_screen; }
test_cpu_load() { fx; ok load 0.38 "$(get cpu_load)"; }
test_memory_free_bytes() { fx; ok memfree $(( (12712+25196+82140)*1024 )) "$(get memory_free)"; }
test_memory_total_bytes() { fx; ok memtotal 262328320 "$(get memory_total)"; }
test_storage_bytes_from_df() {
  fx; ok st_total 1426055168 "$(get storage_total)"; ok st_free $((1241624*1024)) "$(get storage_free)"
  printf 'Filesystem           1K-blocks      Used Available Use%% Mounted on\nsome-very-long-filesystem-name-here\n                       1392632    151008   1241624  11%% /mnt/us\n' > "$STUB_DF/_mnt_us"
  ok st_wrapped $((1241624*1024)) "$(get storage_free)"
}
test_rootfs_used_percent() { fx; ok rootfs 88 "$(get rootfs_used_percent)"; }
test_uptime() { fx; ok uptime 6534 "$(get uptime)"; }
test_battery_voltage_volts() { fx; ok volts 4.071 "$(get battery_voltage)"; }
test_battery_current_ma() { fx; ok cur -29 "$(get battery_current)"; }
test_wifi_signal_percent() {
  fx; ok w100 100 "$(get wifi_signal)"; printf '3/5\n' > "$STUB_LIPC/com.lab126.wifid.signalStrength"; ok w60 60 "$(get wifi_signal)"
  printf 'junk\n' > "$STUB_LIPC/com.lab126.wifid.signalStrength"; no_ wjunk dev_get wifi_signal
  printf '3/0\n' > "$STUB_LIPC/com.lab126.wifid.signalStrength"; no_ wzero dev_get wifi_signal
}
test_kernel_version() { fx; ok kern 2.6.31-rt11-lab126 "$(get kernel_version)"; }
test_ip_and_mac_parse() {
  fx; ok ip 192.168.7.42 "$(get ip_address)"; ok mac aa:bb:cc:dd:ee:ff "$(get mac_address)"; ok ssid HomeNet-5G "$(get ssid)"
  printf 'nothing here\n' > "$STUB_LIPC/com.lab126.wifid.711"; no_ ssid_bad dev_get ssid
  : > "$STUB_IFCONFIG"; no_ ip_none dev_get ip_address
}
test_cpu_usage_first_null_then_percent() {
  fx; no_ cpu_first dev_get cpu_usage; cp "$PROC_ROOT/stat2" "$PROC_ROOT/stat"
  # dtotal=500 (100 user+50 sys+300 idle+50 iowait), didle=350 -> busy 150/500 = 30.0%
  ok cpu_second 30.0 "$(get cpu_usage)"
  no_ cpu_zero dev_get cpu_usage
}
test_unknown_id_returns_1() { fx; no_ unk dev_get nosuch; no_ unk_warmth dev_get warmth; no_ unk_bt dev_get battery_temperature; no_ unk_set dev_set nosuch 1; }
test_capabilities_exclude_warmth_and_battery_temperature() {
  fx; _c=$(dev_capabilities); ok ncaps 23 "$(printf '%s\n' "$_c" | wc -l | tr -d ' ')"
  no_ has_warmth has "$_c" 'warmth.*'; no_ has_bt has "$_c" 'battery_temperature.*'
}
test_capabilities_flags() { fx; _c=$(dev_capabilities); yes_ rs_w has "$_c" 'refresh_screen w'; yes_ co_v has "$_c" 'clock_offset v'; yes_ bright has "$_c" brightness; }
test_identity_model_and_version() {
  fx; _i=$(dev_identity); yes_ i_model has "$_i" 'model=Kindle Paperwhite 1 (EY21)'
  yes_ i_sw has "$_i" 'sw_version=5.3.7'; yes_ i_name has "$_i" 'name=kindle-wall'
  yes_ i_mfr has "$_i" 'manufacturer=Amazon'; yes_ i_mac has "$_i" 'mac=aa:bb:cc:dd:ee:ff'
  no_ i_hw has "$_i" 'hw_version.*'
  STUB_HOSTNAME=; export STUB_HOSTNAME; yes_ i_fallback has "$(dev_identity)" 'name=Kindle'
}
test_serial_only_when_opted_in() {
  fx; no_ ser_off has "$(dev_identity)" 'serial_number=.*'
  CFG_SERIAL=1; yes_ ser_on has "$(dev_identity)" 'serial_number=B0TESTSERIAL0001'
}
test_refuses_non_ey21() {
  fx; printf 'Hardware\t: Something Else\n' > "$PROC_ROOT/cpuinfo"
  ok refuse_out "" "$(dev_capabilities 2>/dev/null)"; yes_ refuse_err test -n "$(dev_capabilities 2>&1 >/dev/null)"
  yes_ refuse_model has "$(dev_identity)" 'model=Unknown Kindle'
}
test_missing_files_return_1() {
  fx; rm -rf "${T:?}/fx/proc" "${T:?}/fx/sys" "${T:?}/fx/lipc" "${T:?}/fx/df"; rm -f "$T/fx/ifconfig"
  for id in battery_level cpu_load cpu_usage memory_total memory_free storage_total storage_free rootfs_used_percent uptime \
    battery_voltage battery_current wifi_signal ip_address ssid mac_address brightness frontlight_on keep_awake charging power_state; do
    no_ "missing_$id" dev_get "$id"; done
  mkdir -p "$T/emptybin"; PATH="$T/emptybin"; no_ missing_cmd_kernel dev_get kernel_version; PATH="$here/stubs/bin:$BASEPATH"
}
test_sensitive_values_not_in_stderr() {
  fx; _e=$( { for id in ip_address ssid mac_address; do dev_get $id; done; dev_identity; } 2>&1 >/dev/null ); ok stderr_empty "" "$_e"
}

for t in brightness_get_rounds brightness_set battery_and_charging power_state_mapping frontlight_on keep_awake_get_set refresh_screen_set \
  cpu_load memory_free_bytes memory_total_bytes storage_bytes_from_df rootfs_used_percent uptime battery_voltage_volts battery_current_ma \
  wifi_signal_percent kernel_version ip_and_mac_parse cpu_usage_first_null_then_percent unknown_id_returns_1 \
  capabilities_exclude_warmth_and_battery_temperature capabilities_flags identity_model_and_version serial_only_when_opted_in \
  refuses_non_ey21 missing_files_return_1 sensitive_values_not_in_stderr; do "test_$t"; done

# ---- integration: real agent.sh + real ey21.sh + stubs against mock_ha.py
fx
D="$T/int"; mkdir -p "$D"; LOG="$D/log"; : > "$LOG"
HELLO='{"status":200,"body":{"contract":1,"heartbeat_s":2,"poll_wait_s":1,"config":{"config_rev":1,"enabled":["battery_level","brightness"],"interval_s":{}}}}'
CMD='{"status":200,"body":{"config_rev":1,"commands":[{"id":"c1","capability":"brightness","value":50,"issued_at":1763200000}]}}'
printf '{"hello":[%s],"state":[{"status":200,"body":{"config_rev":1}}],"commands":[%s,{"status":200,"body":{"config_rev":1,"commands":[]}}],"config":[{}]}' "$HELLO" "$CMD" > "$D/scen.json"
python3 "$here/mock_ha.py" "$D/scen.json" "$D/port" "$LOG" >"$D/mock.out" 2>&1 & MOCK_PID=$!
_i=0; while [ ! -f "$D/port" ] && [ $_i -lt 50 ]; do sleep 0.1; _i=$((_i+1)); done
printf 'url = http://127.0.0.1:%s/api/panel_control/k/\ntoken = Maple-Orbit-Tiger-Quilt-Ember\n' "$(cat "$D/port")" > "$D/config"
PANEL_STATUS="$D/status" PANEL_CONFIG="$D/config" PANEL_TMP="$D/tmp" DEVICE_LAYER="$LAYER" PANEL_BACKOFF_BASE=1 \
  sh "$here/../panel-control/bin/agent.sh" >"$D/agent.out" 2>&1 & AGENT_PID=$!
_i=0; while [ $_i -lt 80 ] && ! grep -q 'flIntensity 12' "$STUB_LOG" 2>/dev/null; do sleep 0.1; _i=$((_i+1)); done
sleep 1
hello_line=$(grep '/hello ' "$LOG" | head -n 1)
ok int_hello_23 23 "$(printf '%s' "$hello_line" | grep -o '"id":"[a-z_]*"' | sort -u | wc -l | tr -d ' ')"
no_ int_hello_warmth sh -c "printf '%s' '$hello_line' | grep -q warmth"
no_ int_hello_battery_temp sh -c "printf '%s' '$hello_line' | grep -q battery_temperature"
yes_ int_state_battery sh -c "grep '/state ' '$LOG' | grep -q '\"battery_level\":88'"
yes_ int_state_brightness sh -c "grep '/state ' '$LOG' | grep -q '\"brightness\":13'"
ok int_set_call "lipc-set-prop com.lab126.powerd flIntensity 12" "$(head -n 1 "$STUB_LOG")"
yes_ int_no_schema_err sh -c "! grep -q -e '-ERROR' '$LOG'"

echo "t_ey21: $N checks, $FAILS failed"
[ $FAILS = 0 ]
