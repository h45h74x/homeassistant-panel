#!/bin/sh
# Panel Control agent (POSIX sh / BusyBox ash 1.17). Contract: control/contract/README.md.
# Env: PANEL_PID PANEL_CONFIG PANEL_STATUS PANEL_LOG PANEL_DISPLAY_FLAG PANEL_DISPLAY_MIN PANEL_TMP DEVICE_LAYER PANEL_BACKOFF_BASE PANEL_LOCKOUT_WAIT PANEL_AUTH_WAIT
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh" || exit 2
AGENT_VERSION=0.1.0
PANEL_CONFIG=${PANEL_CONFIG:-/mnt/us/extensions/panel-control/config}
PANEL_STATUS=${PANEL_STATUS:-/tmp/panel-control.status}
PANEL_TMP=${PANEL_TMP:-/tmp/panel-control.d}
PANEL_LOG=${PANEL_LOG:-/tmp/panel-control.log}
PANEL_DISPLAY_FLAG=${PANEL_DISPLAY_FLAG:-/mnt/us/extensions/panel-control/display.on}
DISP_MIN=${PANEL_DISPLAY_MIN:-20}
# The agent records its OWN pid: on BusyBox `sh agent.sh &` leaves $! pointing at a forked wrapper, not the agent.
[ -n "${PANEL_PID:-}" ] && printf '%s\n' "$$" > "$PANEL_PID"
DEVICE_LAYER=${DEVICE_LAYER:-$HERE/ey21.sh}
BO_BASE=${PANEL_BACKOFF_BASE:-5}
LOCKOUT_WAIT=${PANEL_LOCKOUT_WAIT:-300}
AUTH_WAIT=${PANEL_AUTH_WAIT:-60}

# ---- status file: written atomically, only when content changed (last_contact at most every 60 s)
ST_STATE=; ST_ERR=; LAST_CONTACT=; ST_WRITTEN=; ST_WLC=0
set_status() { # <state> <error>
  ST_STATE=$1; ST_ERR=$2
  _s="state=$ST_STATE
last_error=$ST_ERR
agent_version=$AGENT_VERSION"
  if [ "$_s" != "$ST_WRITTEN" ] || { [ -n "$LAST_CONTACT" ] && [ $((LAST_CONTACT-ST_WLC)) -ge 60 ]; }; then
    printf '%s\nlast_contact=%s\n' "$_s" "$LAST_CONTACT" > "$PANEL_STATUS.tmp" 2>/dev/null \
      && mv "$PANEL_STATUS.tmp" "$PANEL_STATUS" 2>/dev/null
    ST_WRITTEN=$_s; ST_WLC=${LAST_CONTACT:-0}
  fi
  display_tick
}
# ---- on-screen status: only when the layer has dev_display AND the flag file exists. Redraw only when
# state or the last two log lines changed and at least DISP_MIN s passed; the clock is refreshed only on a redraw.
case "$DISP_MIN" in ''|*[!0-9]*|0*) DISP_MIN=20 ;; esac
CONTACT_HMS=; DISP_ON=0; DISP_SIG=; DISP_LAST=0; HAVE_DISP=0; LOG_SZ=; LOG1=; LOG2=
display_tick() {
  [ $HAVE_DISP = 1 ] || return 0
  if [ ! -f "$PANEL_DISPLAY_FLAG" ]; then
    [ $DISP_ON = 0 ] || { DISP_ON=0; DISP_SIG=; dev_display_clear >/dev/null 2>&1; }
    return 0
  fi
  DISP_ON=1
  _sz=$(wc -c < "$PANEL_LOG" 2>/dev/null)
  [ "$_sz" = "$LOG_SZ" ] || { LOG_SZ=$_sz; log_last2; }   # log unchanged: skip the forks
  _sig="$ST_STATE|$LOG1|$LOG2"
  [ "$_sig" != "$DISP_SIG" ] || return 0
  _dn=$(date +%s)
  if [ "$_dn" -ge "$DISP_LAST" ] 2>/dev/null && [ $((_dn-DISP_LAST)) -lt "$DISP_MIN" ]; then return 0; fi
  DISP_SIG=$_sig; DISP_LAST=$_dn
  dev_display "Panel Control: $ST_STATE ${CONTACT_HMS:-no contact yet}" "$LOG1" "$LOG2" >/dev/null 2>&1
  return 0
}
# nap <s>: sleep; while the display is on, wake each second so a redraw deferred by DISP_MIN is not stuck behind a long wait
nap() {
  if [ $HAVE_DISP = 1 ] && [ -f "$PANEL_DISPLAY_FLAG" ]; then
    _nn=$1; while [ "$_nn" -gt 0 ]; do sleep 1; _nn=$((_nn-1)); display_tick; done
  else sleep "$1"; fi
}
# ---- event log in RAM: "HH:MM:SS message", never secrets; bounded (over 60 lines keeps the last 40)
plog() {
  _lm=$(printf '%s' "$1" | sed 's/[[:cntrl:]]//g' | cut -c1-80)
  printf '%s %s\n' "$(date +%H:%M:%S)" "$_lm" >> "$PANEL_LOG" 2>/dev/null || return 0
  if [ "$(wc -l < "$PANEL_LOG" 2>/dev/null)" -gt 60 ] 2>/dev/null; then
    tail -n 40 "$PANEL_LOG" > "$PANEL_LOG.tmp" 2>/dev/null && mv "$PANEL_LOG.tmp" "$PANEL_LOG" 2>/dev/null
  fi
  return 0
}
LASTFAIL=
flog() { [ "$1" = "$LASTFAIL" ] || { LASTFAIL=$1; plog "$1"; }; }   # a failure streak logs once per distinct message
die() { set_status error "$1"; exit 2; }

# layer first (functions only), so that die() can already draw the error state
if [ -r "$DEVICE_LAYER" ]; then
  . "$DEVICE_LAYER"
  if type dev_display >/dev/null 2>&1; then HAVE_DISP=1; fi
fi
load_config "$PANEL_CONFIG" > "$PANEL_STATUS.err" 2>&1; _rc=$?   # not in $(): it sets CFG_* globals
_why=$(cat "$PANEL_STATUS.err" 2>/dev/null); rm -f "$PANEL_STATUS.err"
[ $_rc = 0 ] || die "${_why:-bad config}"
[ -r "$DEVICE_LAYER" ] || die "device layer missing"

# single instance owns this dir (launcher enforces that); holds only the curl config and scratch files
(umask 077; mkdir -p "$PANEL_TMP") || die "cannot create tmp dir"
rm -f "$PANEL_TMP"/*
trap 'rm -f "$PANEL_TMP"/*; rmdir "$PANEL_TMP" 2>/dev/null' EXIT
# token goes via a 0600 curl config file so it never shows up in `ps`
( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$(printf '%s' "$CFG_TOKEN" | sed 's/\\/\\\\/g; s/"/\\"/g')" > "$PANEL_TMP/curl.cfg" )

safe_id() { case "$1" in ''|*[!a-z_]*) return 1 ;; esac; }

# ---- the single HTTP function: sets HTTP_CODE (000 on curl failure) and HTTP_BODY
HTTP_T=10; HTTP_CODE=000; HTTP_BODY=; CURL_RC=0
http_call() { # <method> <path> [body-file]
  rm -f "$PANEL_TMP/resp"
  if [ "$1" = POST ]; then
    HTTP_CODE=$(curl -sS -m "$HTTP_T" --connect-timeout 5 -K "$PANEL_TMP/curl.cfg" -o "$PANEL_TMP/resp" \
      -w '%{http_code}' -H 'Content-Type: application/json' --data-binary "@$3" "$CFG_URL/$2" 2>/dev/null)
  else
    HTTP_CODE=$(curl -sS -m "$HTTP_T" --connect-timeout 5 -K "$PANEL_TMP/curl.cfg" -o "$PANEL_TMP/resp" \
      -w '%{http_code}' "$CFG_URL/$2" 2>/dev/null)
  fi
  CURL_RC=$?
  HTTP_T=10
  case "$HTTP_CODE" in [0-9][0-9][0-9]) ;; *) HTTP_CODE=000 ;; esac
  HTTP_BODY=$(cat "$PANEL_TMP/resp" 2>/dev/null)
}

# chk: call after http_call. 0 on 200; otherwise sets status, waits as needed, returns 1.
BO=$BO_BASE; NEED_HELLO=1; B409=1; APPLIED=0
chk() {
  case "$HTTP_CODE" in
    200) BO=$BO_BASE; _d=$(date '+%s %H:%M:%S'); LAST_CONTACT=${_d% *}; CONTACT_HMS=${_d#* }
         [ -z "$LASTFAIL" ] || { LASTFAIL=; plog online; }
         set_status running ""; return 0 ;;
    409) plog "409 re-hello"; NEED_HELLO=1; nap "$B409"; B409=$((B409*2)); [ $B409 -le 120 ] || B409=120; return 1 ;;
    401) flog "unauthorized (check token)"; set_status error "unauthorized (check token)"; nap "$AUTH_WAIT"; return 1 ;;
    429) flog "locked out, wait ${LOCKOUT_WAIT}s"; set_status backoff "locked out"; nap "$LOCKOUT_WAIT"; return 1 ;;
    000) fail_soft "curl error $CURL_RC" ;;
    *) fail_soft "http $HTTP_CODE" ;;
  esac
  return 1
}
fail_soft() { # <reason>: backoff, doubling to 120 s
  case "$1" in "curl error"*) flog "HA unreachable, retry in ${BO}s" ;; *) flog "$1, retry in ${BO}s" ;; esac
  set_status backoff "$1"; nap "$BO"; BO=$((BO*2)); [ $BO -le 120 ] || BO=120
}

# ---- device capabilities
CAPS=; READABLE=
read_caps() {
  _caps=$(dev_capabilities)
  while read -r _id _flag; do
    safe_id "$_id" || continue
    CAPS="$CAPS $_id"
    eval "cap_$_id=\${_flag:-r}"
    case "$_flag" in w|v) ;; *) READABLE="$READABLE $_id" ;; esac
  done <<EOF
$_caps
EOF
}
declared() { case " $CAPS " in *" $1 "*) return 0 ;; esac; return 1; }
readable() { case " $READABLE " in *" $1 "*) return 0 ;; esac; return 1; }

# ---- config (enabled list + intervals)
CFG_REV=; ENABLED=; IV_IDS=; HB=60; PW=25
apply_config() { # <json body>
  _cl=$(parse_config "$1")
  [ -n "$_cl" ] || return 1
  _en=; _iv=
  while read -r _k _a _b; do
    case "$_k" in
      rev) CFG_REV=$_a ;;
      enabled) _en="$_a $_b" ;;
      interval) safe_id "$_a" && { eval "iv_$_a=$_b"; _iv="$_iv $_a"; } ;;
    esac
  done <<EOF
$_cl
EOF
  _e2=
  for _id in $_en; do safe_id "$_id" && readable "$_id" && _e2="$_e2 $_id"; done
  # intervals of ids that dropped out stop applying
  for _id in $IV_IDS; do case " $_iv " in *" $_id "*) ;; *) eval "iv_$_id=" ;; esac; done
  ENABLED=$_e2; IV_IDS=$_iv
  return 0
}
reset_last() { for _id in $READABLE; do eval "last_$_id=; due_$_id=0"; done; }

# ---- hello
json_hello() {
  _name=$(printf '%s' "${CFG_NAME}" | cut -c1-200)
  _man=; _model=; _sw=; _hw=; _mac=; _ser=; _idn=$(dev_identity)
  while IFS== read -r _k _v; do
    _v=$(printf '%s' "$_v" | cut -c1-200)
    case "$_k" in
      name) [ -n "$CFG_NAME" ] || _name=$_v ;;
      manufacturer) _man=$_v ;; model) _model=$_v ;; sw_version) _sw=$_v ;;
      hw_version) _hw=$_v ;; mac) _mac=$_v ;; serial_number) _ser=$_v ;;
    esac
  done <<EOF
$_idn
EOF
  printf '{"contract":1,"agent_version":"%s","device":{"name":%s,"manufacturer":%s,"model":%s,"sw_version":%s' \
    "$AGENT_VERSION" "$(json_str "$_name")" "$(json_str "$_man")" "$(json_str "$_model")" "$(json_str "$_sw")"
  [ -z "$_hw" ] || printf ',"hw_version":%s' "$(json_str "$_hw")"
  [ -z "$_mac" ] || printf ',"mac":%s' "$(json_str "$_mac")"
  [ "$CFG_SERIAL" = 1 ] && [ -n "$_ser" ] && printf ',"serial_number":%s' "$(json_str "$_ser")"
  printf '},"capabilities":['
  _first=1
  for _id in $CAPS; do
    [ $_first = 1 ] || printf ','
    _first=0; printf '{"id":"%s"}' "$_id"
  done
  printf ']}'
}
do_hello() {
  json_hello > "$PANEL_TMP/hello.json"
  http_call POST hello "$PANEL_TMP/hello.json"
  chk || return 1
  _h=$(json_int heartbeat_s "$HTTP_BODY"); _p=$(json_int poll_wait_s "$HTTP_BODY")
  if [ -z "$_h" ] || [ -z "$_p" ] || ! apply_config "$HTTP_BODY"; then
    fail_soft "bad hello response"; return 1
  fi
  HB=$_h; PW=$_p; NEED_HELLO=0; LAST_STATE=0
  set -- $CAPS; plog "hello ok ($# caps)"
  reset_last
  return 0
}

# check_rev <body>: fetch config when the host's config_rev differs
check_rev() {
  _r=$(json_int config_rev "$1")
  if [ -n "$_r" ] && [ "$_r" != "$CFG_REV" ]; then
    http_call GET config
    if chk; then
      if apply_config "$HTTP_BODY"; then reset_last; set -- $ENABLED; plog "config rev applied ($# enabled)"; fi
    fi
  fi
}

# ---- collect values: interval ids when due, others when changed, forced ids always
VALS=; ACKS=; FORCE=; LAST_STATE=0
collect() {
  VALS=; _now=$(date +%s)
  for _id in $ENABLED; do
    eval "_iv=\${iv_$_id:-}; _due=\${due_$_id:-0}"
    _f=0; case " $FORCE " in *" $_id "*) _f=1 ;; esac
    if [ -n "$_iv" ]; then
      [ $_f = 1 ] || [ "$_now" -ge "$_due" ] || continue
      eval "due_$_id=$((_now+_iv))"
    fi
    if _v=$(dev_get "$_id"); then :; else _v=; fi
    _j=$(json_val "$_v")
    if [ -z "$_iv" ] && [ $_f = 0 ]; then
      eval "_l=\${last_$_id:-}"
      [ "$_j" != "$_l" ] || continue
    fi
    eval "last_$_id=\$_j"
    VALS="$VALS\"$_id\":$_j,"
  done
  FORCE=
}
post_state() {
  printf '{"time":%s,"values":{%s},"acks":[%s]}' "$(date +%s)" "${VALS%,}" "${ACKS%,}" > "$PANEL_TMP/state.json"
  http_call POST state "$PANEL_TMP/state.json"
  if chk; then
    _sb=$HTTP_BODY   # check_rev's GET config overwrites HTTP_BODY
    if [ -z "$(json_int config_rev "$_sb")" ]; then fail_soft "bad response"; reset_last; return; fi
    ACKS=; LAST_STATE=$(date +%s); check_rev "$_sb"
  else
    reset_last   # values may not have arrived: resend everything
  fi
}

# ---- commands
apply_commands() { # <commands body>
  _cmds=$(parse_commands "$1")
  [ -n "$_cmds" ] || return 0
  APPLIED=1
  while read -r _cid _cap _val; do
    _err=
    if ! safe_id "$_cap" || ! declared "$_cap"; then _err="capability not declared"
    else
      eval "_fl=\$cap_$_cap"
      [ "$_fl" = v ] && _err="capability is virtual"
    fi
    if [ -z "$_err" ]; then
      [ "$_val" = null ] && _val=press
      if _msg=$(dev_set "$_cap" "$_val"); then
        readable "$_cap" && FORCE="$FORCE $_cap"
      else
        _err=${_msg:-set failed}
      fi
    fi
    if [ -z "$_err" ]; then plog "cmd $_cap ok"; ACKS="$ACKS{\"id\":\"$_cid\",\"ok\":true},"
    else _lc=$_cap; safe_id "$_lc" || _lc='?'; plog "cmd $_lc FAILED: $_err"; ACKS="$ACKS{\"id\":\"$_cid\",\"ok\":false,\"error\":$(json_str "$_err")},"; fi
  done <<EOF
$_cmds
EOF
}
poll_commands() {
  _now=$(date +%s); _next=$((LAST_STATE+HB))
  for _id in $ENABLED; do
    eval "_iv=\${iv_$_id:-}; _due=\${due_$_id:-0}"
    [ -n "$_iv" ] && [ "$_due" -lt "$_next" ] && _next=$_due
  done
  _w=$((_next-_now)); [ $_w -le $PW ] || _w=$PW; [ $_w -ge 1 ] || _w=1
  HTTP_T=$((_w+10))
  http_call GET "commands?wait=$_w"
  if chk; then
    _cb=$HTTP_BODY   # commands are fire-once: apply them before check_rev clobbers HTTP_BODY
    if [ -z "$(json_int config_rev "$_cb")" ]; then fail_soft "bad response"; return; fi
    B409=1
    apply_commands "$_cb"; check_rev "$_cb"
  fi
}

read_caps
set_status backoff "starting"
plog started
PREV_NOW=0
while :; do
  display_tick
  _now=$(date +%s)
  case "$_now" in ''|*[!0-9]*) fail_soft "bad clock"; continue ;; esac
  # clock set backwards (Kindle syncs time after Wi-Fi): restart heartbeat and interval timers
  if [ "$_now" -lt "$PREV_NOW" ]; then LAST_STATE=0; reset_last; fi
  PREV_NOW=$_now; _t0=$_now; APPLIED=0
  if [ $NEED_HELLO = 1 ]; then do_hello || continue; fi
  collect
  if [ -n "$VALS" ] || [ -n "$ACKS" ] || [ $((_now-LAST_STATE)) -ge "$HB" ]; then
    post_state
    [ $NEED_HELLO = 0 ] || continue
  fi
  poll_commands
  # floor: never spin faster than 1 iteration/s unless commands were just applied
  _e=$(date +%s)
  [ "$APPLIED" = 1 ] || [ $((_e-_t0)) -ge 1 ] 2>/dev/null || sleep 1
done
