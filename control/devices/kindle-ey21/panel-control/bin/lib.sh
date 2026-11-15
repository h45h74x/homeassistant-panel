# Sourced helper library (POSIX sh / BusyBox ash 1.17). Defines functions only.
# Contract: control/contract/README.md ("Parsing commands without jq").

json_str() {
  printf '"%s"' "$(printf '%s' "$1" | tr -d '\001-\037\177' | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

# shortcut: a numeric-looking text value (e.g. "3") is sent as a number, upgrade if a text capability needs it.
json_val() {
  case "$1" in
    '') printf 'null' ;;
    true|false) printf '%s' "$1" ;;
    *) # newline would let grep match one line only, so route it to json_str
       case "$1" in *"
"*) json_str "$1"; return ;; esac
       if printf '%s' "$1" | grep -q -e '^-\{0,1\}0\(\.[0-9][0-9]*\)\{0,1\}$' -e '^-\{0,1\}[1-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}$'; then
         printf '%s' "$1"
       else
         json_str "$1"
       fi ;;
  esac
}

json_int() {
  printf '%s' "$2" | sed -n 's/.*"'"$1"'":\(-\{0,1\}[0-9][0-9]*\).*/\1/p' | head -n 1
}

parse_commands() {
  printf '%s' "$1" | tr '}' '\n' | sed -n 's/.*"id":"\([a-z0-9]*\)","capability":"\([a-z_]*\)","value":\([^,]*\),.*/\1 \2 \3/p'
}

parse_config() {
  _pc_rev=$(json_int config_rev "$1")
  [ -n "$_pc_rev" ] || return 0
  echo "rev $_pc_rev"
  printf 'enabled %s\n' "$(printf '%s' "$1" | sed -n 's/.*"enabled":\[\([^]]*\)\].*/\1/p' | tr -d '"' | tr ',' ' ')"
  printf '%s' "$1" | sed -n 's/.*"interval_s":{\([^}]*\)}.*/\1/p' | tr ',' '\n' \
    | sed -n 's/^"\([a-z0-9_]*\)":\([0-9][0-9]*\)$/interval \1 \2/p'
  return 0
}

# _trim <text>: sets _T without leading/trailing space or tab
_trim() {
  _T=$(printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
}

# load_config <file>: parsed line by line, never sourced or eval'd.
load_config() {
  CFG_URL=; CFG_TOKEN=; CFG_NAME=; CFG_SERIAL=
  [ -r "$1" ] || { echo "config not readable: $1"; return 1; }
  _lc_bom=$(printf '\357\273\277')
  _lc_content=$(tr -d '\r' < "$1")
  _lc_first=1
  while IFS= read -r _lc_line; do
    if [ $_lc_first = 1 ]; then _lc_first=0; _lc_line=${_lc_line#"$_lc_bom"}; fi
    _trim "$_lc_line"; _lc_line=$_T
    case "$_lc_line" in ''|'#'*) continue ;; esac
    case "$_lc_line" in *=*) ;; *) continue ;; esac
    _trim "${_lc_line%%=*}"; _lc_key=$_T
    _trim "${_lc_line#*=}"; _lc_val=$_T
    if [ ${#_lc_val} -ge 2 ]; then
      case "$_lc_val" in \"*\") _lc_val=${_lc_val#\"}; _lc_val=${_lc_val%\"} ;; esac
    fi
    case "$_lc_key" in
      url) CFG_URL=$_lc_val ;;
      token) CFG_TOKEN=$_lc_val ;;
      device_name) CFG_NAME=$_lc_val ;;
      send_serial) [ "$_lc_val" = 1 ] && CFG_SERIAL=1 ;;
    esac
  done <<EOF
$_lc_content
EOF
  while :; do case "$CFG_URL" in */) CFG_URL=${CFG_URL%/} ;; *) break ;; esac; done
  case "$CFG_URL" in http://?*|https://?*) ;; *) echo "config: url missing or not http(s)://"; return 1 ;; esac
  [ -n "$CFG_TOKEN" ] || { echo "config: token missing"; return 1; }
  return 0
}
