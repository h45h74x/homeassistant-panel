#!/bin/sh
# Panel Control agent (POSIX sh / BusyBox ash 1.17). Contract: control/contract/README.md.
# Env: PANEL_CONFIG PANEL_STATUS PANEL_TMP DEVICE_LAYER PANEL_BACKOFF_BASE PANEL_LOCKOUT_WAIT PANEL_AUTH_WAIT
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh" || exit 2
AGENT_VERSION=0.1.0
PANEL_CONFIG=${PANEL_CONFIG:-/mnt/us/extensions/panel-control/config}
PANEL_STATUS=${PANEL_STATUS:-/tmp/panel-control.status}
PANEL_TMP=${PANEL_TMP:-/tmp/panel-control.d}
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
}
die() { set_status error "$1"; exit 2; }

load_config "$PANEL_CONFIG" > "$PANEL_STATUS.err" 2>&1; _rc=$?   # not in $(): it sets CFG_* globals
_why=$(cat "$PANEL_STATUS.err" 2>/dev/null); rm -f "$PANEL_STATUS.err"
[ $_rc = 0 ] || die "${_why:-bad config}"
[ -r "$DEVICE_LAYER" ] || die "device layer missing"
. "$DEVICE_LAYER"

# single instance owns this dir (launcher enforces that); holds only the curl config and scratch files
(umask 077; mkdir -p "$PANEL_TMP") || die "cannot create tmp dir"
rm -f "$PANEL_TMP"/*
trap 'rm -f "$PANEL_TMP"/*; rmdir "$PANEL_TMP" 2>/dev/null' EXIT
# token goes via a 0600 curl config file so it never shows up in `ps`
( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$CFG_TOKEN" > "$PANEL_TMP/curl.cfg" )

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
BO=$BO_BASE; NEED_HELLO=1
chk() {
  case "$HTTP_CODE" in
    200) BO=$BO_BASE; LAST_CONTACT=$(date +%s); set_status running ""; return 0 ;;
    409) NEED_HELLO=1; return 1 ;;
    401) set_status error "unauthorized (check token)"; sleep "$AUTH_WAIT"; return 1 ;;
    429) set_status backoff "locked out"; sleep "$LOCKOUT_WAIT"; return 1 ;;
    000) fail_soft "curl error $CURL_RC" ;;
    *) fail_soft "http $HTTP_CODE" ;;
  esac
  return 1
}
fail_soft() { # <reason>: backoff, doubling to 120 s
  set_status backoff "$1"; sleep "$BO"; BO=$((BO*2)); [ $BO -le 120 ] || BO=120
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
  reset_last
  return 0
}

# check_rev <body>: fetch config when the host's config_rev differs
check_rev() {
  _r=$(json_int config_rev "$1")
  if [ -n "$_r" ] && [ "$_r" != "$CFG_REV" ]; then
    http_call GET config
    if chk; then apply_config "$HTTP_BODY" && reset_last; fi
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
    ACKS=; LAST_STATE=$(date +%s); check_rev "$HTTP_BODY"
  else
    reset_last   # values may not have arrived: resend everything
  fi
}

# ---- commands
apply_commands() { # <commands body>
  _cmds=$(parse_commands "$1")
  [ -n "$_cmds" ] || return 0
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
    if [ -z "$_err" ]; then ACKS="$ACKS{\"id\":\"$_cid\",\"ok\":true},"
    else ACKS="$ACKS{\"id\":\"$_cid\",\"ok\":false,\"error\":$(json_str "$_err")},"; fi
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
  if chk; then check_rev "$HTTP_BODY"; apply_commands "$HTTP_BODY"; fi
}

read_caps
set_status backoff "starting"
while :; do
  if [ $NEED_HELLO = 1 ]; then do_hello || continue; fi
  collect
  _now=$(date +%s)
  if [ -n "$VALS" ] || [ -n "$ACKS" ] || [ $((_now-LAST_STATE)) -ge "$HB" ]; then
    post_state
    [ $NEED_HELLO = 0 ] || continue
  fi
  poll_commands
done
