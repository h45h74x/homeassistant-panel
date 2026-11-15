#!/bin/sh
here=$(cd "$(dirname "$0")" && pwd)
FIX="$here/../../../contract/fixtures/valid"
. "$here/../panel-control/bin/lib.sh" || exit 1
PATH="$here/stubs/busybox-tr:$PATH"   # tr without ranges/classes, like BusyBox 1.17
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILS=0; N=0
assert_eq() { N=$((N+1)); if [ "$2" != "$3" ]; then FAILS=$((FAILS+1)); printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"; fi; }
nl='
'

assert_eq json_str "\"a\\\"b\\\\c\"" "$(json_str 'a"b\c')"
tab=$(printf '\t')
assert_eq json_str_ws '"ab"' "$(json_str "a${tab}b$nl")"
assert_eq json_str_ctl '"ab"' "$(json_str "$(printf 'a\001\177b')")"
assert_eq json_str_order '"\\\""' "$(json_str '\"')"
assert_eq json_str_hyphen '"a-b"' "$(json_str 'a-b')"
assert_eq json_str_hyphens '"x-y_z.1-2"' "$(json_str 'x-y_z.1-2')"
assert_eq json_str_ctl_all '"ab"' "$(json_str "$(printf 'a\001\037\177\tb')")"
assert_eq json_str_multiline '"ab"' "$(json_str "a${nl}b")"
assert_eq json_str_oneline 0 "$(json_str "a${nl}b${nl}c" | wc -l | tr -d ' ')"
assert_eq json_str_esc_ctl '"a\\\"b"' "$(json_str "$(printf 'a\001\\"\177b')")"
assert_eq val_nl '"5abc"' "$(json_val "5${nl}abc")"
for v in 0 -0 0.5 -12 1.5 40.5; do assert_eq "val_num_$v" "$v" "$(json_val $v)"; done
for v in 007 +5 .5 5. 1e3 0x10 -; do assert_eq "val_str_$v" "\"$v\"" "$(json_val $v)"; done
assert_eq val_true true "$(json_val true)"
assert_eq val_int -12 "$(json_val -12)"
assert_eq val_float 1.5 "$(json_val 1.5)"
assert_eq val_ver '"5.6.1"' "$(json_val 5.6.1)"
assert_eq val_empty null "$(json_val '')"
assert_eq val_text '"hi"' "$(json_val hi)"

assert_eq cmd_brightness "c1 brightness 40" "$(parse_commands "$(cat $FIX/commands-brightness.json)")"
assert_eq cmd_press "c1 refresh_screen null${nl}c2 keep_awake true${nl}c3 brightness 40.5" "$(parse_commands "$(cat $FIX/commands-press-toggle.json)")"
assert_eq cmd_two "a1 brightness 5${nl}b2 warmth 0" "$(parse_commands '{"config_rev":2,"commands":[{"id":"a1","capability":"brightness","value":5,"issued_at":1},{"id":"b2","capability":"warmth","value":0,"issued_at":2}]}')"
assert_eq cmd_garbage "" "$(parse_commands '<html>nope</html>')"
assert_eq cmd_empty "" "$(parse_commands '')"

assert_eq cfg_basic "rev 1${nl}enabled brightness battery_level${nl}interval battery_level 60" "$(parse_config "$(cat $FIX/config-basic.json)")"
assert_eq cfg_garbage "" "$(parse_config '<html>x</html>')"
assert_eq cfg_empty "" "$(parse_config '')"
assert_eq json_int 60 "$(json_int heartbeat_s "$(cat $FIX/hello-response-basic.json)")"

# load_config
printf '\357\273\277# comment\r\n\r\nurl = "http://ha:8123/api/panel_control/k/"\r\ntoken = Maple-Orbit-Tiger-Quilt-Ember\r\n' > "$TMP/crlf"
assert_eq crlf_has_cr 4 "$(grep -c "$(printf '\r')" "$TMP/crlf")"
load_config "$TMP/crlf"; rc=$?
assert_eq lc_rc 0 "$rc"
assert_eq lc_url http://ha:8123/api/panel_control/k "$CFG_URL"
assert_eq lc_token Maple-Orbit-Tiger-Quilt-Ember "$CFG_TOKEN"
assert_eq lc_serial "" "$CFG_SERIAL"

printf 'url=https://h/x\ntoken = "a=b #c d"\ndevice_name = "My Kindle = 1"\nsend_serial=1\nfoo=bar\n' > "$TMP/c2"
load_config "$TMP/c2"
assert_eq lc2_token "a=b #c d" "$CFG_TOKEN"
assert_eq lc2_name "My Kindle = 1" "$CFG_NAME"
assert_eq lc2_serial 1 "$CFG_SERIAL"
printf 'url=https://h/x\ntoken=t\nsend_serial=yes\n' > "$TMP/c3"
load_config "$TMP/c3"; assert_eq lc3_serial "" "$CFG_SERIAL"; assert_eq lc3_name "" "$CFG_NAME"

printf 'url=http://h/x\ntoken=$(touch %s/pwned1)\ndevice_name=`touch %s/pwned2`\n' "$TMP" "$TMP" > "$TMP/c4"
load_config "$TMP/c4"
assert_eq inj_token "\$(touch $TMP/pwned1)" "$CFG_TOKEN"
assert_eq inj_none "" "$(ls "$TMP" | grep pwned)"

printf '\357\273\277url=http://h/\ntoken=t\n' > "$TMP/c5"
load_config "$TMP/c5"; assert_eq bom_first_line http://h "$CFG_URL"

printf 'url=http://h/x\n' > "$TMP/c6"
assert_eq no_token_rc 1 "$(load_config "$TMP/c6" >/dev/null; echo $?)"
assert_eq no_token_msg 1 "$(load_config "$TMP/c6" | grep -c .)"
printf 'url=ha:8123\ntoken=t\n' > "$TMP/c7"
assert_eq bad_url_rc 1 "$(load_config "$TMP/c7" >/dev/null; echo $?)"
assert_eq missing_file_rc 1 "$(load_config "$TMP/nope" >/dev/null; echo $?)"

printf 'url=http://h\ntoken\t=\t\tT1\t\n\tdevice_name\t=\t"N M"\t\nsend_serial=1' > "$TMP/c8"
load_config "$TMP/c8"
assert_eq tab_token T1 "$CFG_TOKEN"
assert_eq tab_key_name "N M" "$CFG_NAME"
assert_eq nonl_last 1 "$CFG_SERIAL"

echo "$N assertions, $FAILS failed"
[ $FAILS = 0 ]
