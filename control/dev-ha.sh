#!/bin/sh
# Interim dev Home Assistant for the Control integration. It runs the SAME build output that a real
# HA gets (control/dist/custom_components/panel_control, see build.sh); nothing is installed from source.
#   sh control/dev-ha.sh start|restart|stop|status|reset|logs
#   .venv/bin/python control/dev_ha.py pair [NAME] | states
# Config lives in control/.dev-ha/ (git-ignored). Login: admin / admin (DEV_HA_PASS overrides).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
D="$here/.dev-ha"; PORT=${DEV_HA_PORT:-8123}; HASS="$here/.venv/bin/hass"
lan_ip() { ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1; }
alive() { [ -f "$D/hass.pid" ] && kill -0 "$(cat "$D/hass.pid")" 2>/dev/null; }
# the config API route exists (401, not 404) only once the config component, hence custom integrations, are loaded
up() { [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/config/config_entries/entry" 2>/dev/null)" = 401 ]; }

# HA imports a fixed set of components for service-schema validation (see dev_ha_deps.py); their requirements must be
# installed or the web UI never leaves its loading screen (websocket get_services fails). pymicro-vad / pyspeex-noise
# (voice assistant) have no wheel for Python 3.14 and need g++: dev-stubs/ provides import stubs for the dev HA only.
do_deps() {
  if "$here/.venv/bin/python" -c "import hassil, mutagen, turbojpeg, hass_frontend, ifaddr" 2>/dev/null; then return 0; fi
  echo "installing HA requirements that the web UI needs ..."
  for r in $("$here/.venv/bin/python" "$here/dev_ha_deps.py"); do
    case "$r" in pymicro-vad*|pyspeex-noise*) continue ;; esac
    uv pip install --python "$here/.venv/bin/python" "$r" >/dev/null 2>&1 || echo "warning: could not install $r"
  done
}

do_stop() {
  alive || { echo "dev HA not running"; return 0; }
  kill "$(cat "$D/hass.pid")" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do alive || break; sleep 1; done
  alive && kill -9 "$(cat "$D/hass.pid")" 2>/dev/null || true
  rm -f "$D/hass.pid"; echo "dev HA stopped"
}

do_start() {
  [ -x "$HASS" ] || { echo "no $HASS: create the venv first (see CLAUDE.md)"; exit 1; }
  alive && { echo "dev HA already running (pid $(cat "$D/hass.pid"))"; return 0; }
  do_deps
  sh "$here/build.sh" >/dev/null
  mkdir -p "$D/custom_components"
  rsync -a --delete "$here/dist/custom_components/" "$D/custom_components/"
  ip=${DEV_HA_IP:-$(lan_ip)}; [ -n "$ip" ] || { echo "cannot determine the LAN IP: set DEV_HA_IP"; exit 1; }
  cat > "$D/configuration.yaml" <<YAML
homeassistant:
  name: Panel Dev
  time_zone: ${DEV_HA_TZ:-Europe/Vienna}
  internal_url: http://$ip:$PORT
http:
  server_port: $PORT
api:
config:
logger:
  default: warning
  logs:
    custom_components.panel_control: debug
YAML
  # Seeded login for tests and for you: admin / admin (DEV_HA_PASS overrides). The instance listens on the LAN
  # (the Kindle must reach it), so stop it (sh dev-ha.sh stop) when you are not using it.
  pass=${DEV_HA_PASS:-admin}
  mkdir -p "$D"; printf '%s' "$pass" > "$D/.admin-pass"; chmod 600 "$D/.admin-pass"
  if ! "$HASS" --script auth -c "$D" change_password admin "$pass" 2>/dev/null | grep -q 'Password changed'; then
    "$HASS" --script auth -c "$D" add admin "$pass" >/dev/null
  fi
  # stdio fully detached, otherwise a caller piping our output (| tail) waits for HA to exit
  cd "$D"
  PYTHONPATH="$here/dev-stubs${PYTHONPATH:+:$PYTHONPATH}" setsid "$HASS" -c "$D" > "$D/hass.out" 2>&1 < /dev/null &
  echo $! > "$D/hass.pid"
  echo "starting dev HA (first start installs requirements, up to a few minutes) ..."
  for _ in $(seq 1 150); do
    up && { echo "dev HA up: http://$ip:$PORT (login: admin / $pass)"
            "$here/.venv/bin/python" "$here/dev_ha.py" check 2>&1 | tail -2 || true; return 0; }
    alive || { echo "dev HA exited, see $D/hass.out"; tail -5 "$D/hass.out"; exit 1; }
    sleep 2
  done
  echo "dev HA did not come up in 5 minutes, see $D/hass.out"; exit 1
}

case "${1:-}" in
  start) do_start ;;
  restart) do_stop; do_start ;;
  stop) do_stop ;;
  status) if alive; then up && echo "running (pid $(cat "$D/hass.pid")), API up" || echo "running (pid $(cat "$D/hass.pid")), API not up yet"; else echo "not running"; fi ;;
  reset) do_stop; rm -rf "$D"; echo "dev HA config removed" ;;
  logs) tail -n "${2:-60}" "$D/home-assistant.log" ;;
  *) sed -n 2,7p "$0"; exit 2 ;;
esac
