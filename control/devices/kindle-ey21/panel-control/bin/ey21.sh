# EY21 (Kindle Paperwhite 1) device layer, sourced by agent.sh. Defines functions only.
# Env for tests: PROC_ROOT SYS_ROOT ETC_ROOT EIPS FBINK; lipc/df/ifconfig/uname/hostname come from PATH.
# BusyBox 1.17 ash: no [[ ]], no arrays, basic sed only.

_proc() { printf '%s' "${PROC_ROOT:-/proc}"; }
_sys() { printf '%s' "${SYS_ROOT:-/sys}"; }
_etc() { printf '%s' "${ETC_ROOT:-/etc}"; }
_eips() { printf '%s' "${EIPS:-/usr/sbin/eips}"; }
_BATT=devices/system/yoshi_battery/yoshi_battery0

_isint() { case "$1" in ''|-|*[!0-9-]*|?*-*) return 1 ;; esac; return 0; }
_isnum() { case "$1" in ''|*[!0-9.-]*) return 1 ;; esac; return 0; }
_lg() { # <service> <prop>: value, fails on error/empty
  _o=$(lipc-get-prop "$1" "$2" 2>/dev/null) || return 1
  [ -n "$_o" ] || return 1
  printf '%s' "$_o"
}
_pd() { _lg com.lab126.powerd "$1"; }
_file1() { # <file>: first line
  [ -r "$1" ] || return 1
  _o=$(head -n 1 "$1" 2>/dev/null) || return 1
  [ -n "$_o" ] || return 1
  printf '%s' "$_o"
}
_meminfo() { # <key>: kB
  [ -r "$(_proc)/meminfo" ] || return 1
  awk -v k="$1:" '$1==k{print $2; exit}' "$(_proc)/meminfo"
}
_kb2bytes() { _isint "$1" || return 1; awk -v k="$1" 'BEGIN{printf "%.0f", k*1024}'; }
_df_cols() { # <path> <col 2=total|4=avail|5=use%>: joins wrapped lines first
  _o=$(df -k "$1" 2>/dev/null | awk 'NR>1{s=s" "$0} END{print s}' | awk -v c="$2" '{print $c}')
  [ -n "$_o" ] || return 1
  printf '%s' "$_o"
}
_bright_pct() { # lipc 0..24 -> percent
  _n=$(_pd flIntensity) || return 1
  _isint "$_n" || return 1
  printf '%s' $(( (_n * 100 + 12) / 24 ))
}

dev_identity() {
  _cpu=$(grep -c 'MX50 YOSHIME' "$(_proc)/cpuinfo" 2>/dev/null)
  _h=$(hostname 2>/dev/null | sed 's/[[:cntrl:]]//g' | cut -c1-200)
  printf 'name=%s\nmanufacturer=Amazon\n' "${_h:-Kindle}"
  if [ "${_cpu:-0}" -gt 0 ]; then printf 'model=Kindle Paperwhite 1 (EY21)\n'; else printf 'model=Unknown Kindle\n'; fi
  _sw=$(sed -n 's/^System Software Version:[[:space:]]*//p' "$(_etc)/version.txt" 2>/dev/null | head -n 1 \
    | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]/) {print $i; exit}}')
  [ -n "$_sw" ] && printf 'sw_version=%s\n' "$_sw"
  _m=$(_file1 "$(_sys)/class/net/wlan0/address") && printf 'mac=%s\n' "$_m"
  if [ "${CFG_SERIAL:-0}" = 1 ]; then
    _s=$(_file1 "$(_proc)/usid") && printf 'serial_number=%s\n' "$_s"
  fi
  return 0
}

dev_capabilities() {
  if ! grep -q 'MX50 YOSHIME' "$(_proc)/cpuinfo" 2>/dev/null; then
    echo "ey21: not an EY21 board (no MX50 YOSHIME in cpuinfo), no capabilities declared" >&2
    return 0
  fi
  # warmth: no amber light. battery_temperature: unit unverified, not declared yet.
  printf '%s\n' brightness keep_awake 'refresh_screen w' 'sleep w' battery_level charging frontlight_on power_state \
    cpu_usage cpu_load memory_total memory_free storage_total storage_free rootfs_used_percent \
    'clock_offset v' uptime battery_voltage battery_current wifi_signal ip_address ssid mac_address kernel_version
}

dev_get() {
  case "$1" in
    brightness) _bright_pct ;;
    frontlight_on) _p=$(_bright_pct) || return 1; if [ "$_p" -gt 0 ]; then printf true; else printf false; fi ;;
    keep_awake|charging)
      case "$1" in keep_awake) _v=$(_pd preventScreenSaver) ;; *) _v=$(_pd isCharging) ;; esac || return 1
      case "$_v" in 0) printf false ;; 1) printf true ;; *) return 1 ;; esac ;;
    battery_level) _v=$(_pd battLevel) || return 1; _isint "$_v" || return 1; printf '%s' "$_v" ;;
    power_state)
      _v=$(_pd state) || return 1
      case "$_v" in active) printf active ;; screenSaver|readyToSuspend) printf screensaver ;; *) return 1 ;; esac ;;
    cpu_load)
      _v=$(_file1 "$(_proc)/loadavg") || return 1; _v=${_v%% *}; _isnum "$_v" || return 1; printf '%s' "$_v" ;;
    cpu_usage)
      [ -r "$(_proc)/stat" ] || return 1
      _cur=$(head -n 1 "$(_proc)/stat" | awk '{t=0; for(i=2;i<=8;i++) t+=$i; printf "%.0f %.0f", t, $5+$6}')  # BusyBox awk print uses %.6g for sums > 1e6 (verified on the EY21), so printf
      [ -n "$_cur" ] || return 1
      _f="${PANEL_TMP:-/tmp}/ey21.cpu"; _prev=$(cat "$_f" 2>/dev/null)
      printf '%s\n' "$_cur" > "$_f" 2>/dev/null
      [ -n "$_prev" ] || return 1
      _o=$(awk -v a="$_prev" -v b="$_cur" 'BEGIN{split(a,p," "); split(b,c," "); dt=c[1]-p[1]; di=c[2]-p[2]
        if (dt<=0) exit 1; u=(dt-di)*100/dt; if (u<0) u=0; if (u>100) u=100; printf "%.1f", u}') || return 1
      printf '%s' "$_o" ;;
    memory_total) _v=$(_meminfo MemTotal) && _kb2bytes "$_v" ;;
    memory_free)
      _a=$(_meminfo MemFree); _b=$(_meminfo Buffers); _c=$(_meminfo Cached)
      _isint "$_a" && _isint "$_b" && _isint "$_c" || return 1
      _kb2bytes $((_a + _b + _c)) ;;
    storage_total) _v=$(_df_cols /mnt/us 2) && _kb2bytes "$_v" ;;
    storage_free) _v=$(_df_cols /mnt/us 4) && _kb2bytes "$_v" ;;
    rootfs_used_percent) _v=$(_df_cols / 5) || return 1; _v=${_v%\%}; _isint "$_v" || return 1; printf '%s' "$_v" ;;
    uptime) _v=$(_file1 "$(_proc)/uptime") || return 1; _v=${_v%% *}; _v=${_v%%.*}; _isint "$_v" || return 1; printf '%s' "$_v" ;;
    battery_voltage)
      _v=$(_file1 "$(_sys)/$_BATT/battery_voltage") || return 1; _isint "$_v" || return 1
      awk -v m="$_v" 'BEGIN{printf "%.3f", m/1000}' ;;
    battery_current) _v=$(_file1 "$(_sys)/$_BATT/battery_current") || return 1; _isint "$_v" || return 1; printf '%s' "$_v" ;;
    wifi_signal)
      _v=$(_lg com.lab126.wifid signalStrength) || return 1
      _n=${_v%%/*}; _m=${_v#*/}
      _isint "$_n" && _isint "$_m" && [ "$_m" -gt 0 ] || return 1
      _p=$((_n * 100 / _m)); [ "$_p" -le 100 ] || _p=100; [ "$_p" -ge 0 ] || return 1
      printf '%s' "$_p" ;;
    ip_address)
      _v=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | head -n 1)
      [ -n "$_v" ] || return 1; printf '%s' "$_v" ;;
    mac_address) _file1 "$(_sys)/class/net/wlan0/address" ;;
    ssid)
      _v=$(lipc-get-prop com.lab126.wifid 711 2>/dev/null | sed -n 's/.*AP:[[:space:]]*//p' | head -n 1 \
        | sed 's/[[:space:]]*([^()]*)[[:space:]]*$//' | sed 's/[[:cntrl:]]//g')
      [ -n "$_v" ] || return 1; printf '%s' "$_v" ;;
    kernel_version) _v=$(uname -r 2>/dev/null) || return 1; [ -n "$_v" ] || return 1; printf '%s' "$_v" ;;
    *) return 1 ;;
  esac
}

dev_set() {
  case "$1" in
    brightness)
      _isint "$2" || { echo "brightness needs a number"; return 1; }
      _v=$2; [ "$_v" -ge 0 ] || _v=0; [ "$_v" -le 100 ] || _v=100
      lipc-set-prop com.lab126.powerd flIntensity $(( (_v * 24 + 50) / 100 )) >/dev/null 2>&1 || { echo "lipc write failed"; return 1; } ;;
    keep_awake)
      case "$2" in true) _v=1 ;; false) _v=0 ;; *) echo "keep_awake needs true/false"; return 1 ;; esac
      lipc-set-prop com.lab126.powerd preventScreenSaver "$_v" >/dev/null 2>&1 || { echo "lipc write failed"; return 1; } ;;
    refresh_screen) "$(_eips)" -c >/dev/null 2>&1 || { echo "eips failed"; return 1; } ;;
    sleep) # keep-awake blocks the lock, so clear it first; then the power button path
      lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1 || { echo "lipc write failed"; return 1; }
      lipc-set-prop com.lab126.powerd powerButton 1 >/dev/null 2>&1 || { echo "lipc write failed"; return 1; } ;;
    *) echo "unsupported"; return 1 ;;
  esac
}

# ---- on-screen status block: the bottom three rows via FBINK (47 columns, rows -3..-1). Silent, returns 1 without fbink.
_fbink() { # prints the first executable fbink
  for _f in "${FBINK:-}" /var/local/kmc/bin/fbink /mnt/us/libkh/bin/fbink; do
    [ -n "$_f" ] && [ -x "$_f" ] && { printf '%s' "$_f"; return 0; }
  done
  return 1
}
_dline() { # printable ASCII only, one line, max 46 chars, never empty
  _o=$(printf '%s' "$1" | tr '\n' ' ' | sed 's/[[:cntrl:]]//g' | LC_ALL=C sed 's/[^ -~]//g' | cut -c1-46)
  _o=${_o:- }; case $_o in -*) _o=" $_o" ;; esac   # a leading '-' would be parsed as an fbink option
  printf '%s' "$_o"
}
dev_display() { # <line1> <line2> <line3>
  _fb=$(_fbink) || return 1
  _y=-3
  for _t in "$1" "$2" "$3"; do
    "$_fb" -q -p -y "$_y" "$(_dline "$_t")" >/dev/null 2>&1
    _y=$((_y+1))
  done
  return 0
}
dev_display_clear() { dev_display ' ' ' ' ' '; }
