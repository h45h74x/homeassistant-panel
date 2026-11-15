"""Prints the pip requirements of the HA components that HA imports for service-schema validation.

HA only installs an integration's requirements when it sets that integration up, but
homeassistant.helpers.service._base_components() imports a fixed set of components (assist_satellite -> assist_pipeline
-> pymicro_vad, camera -> turbojpeg, ...) just to validate service schemas. If one of those packages is missing,
the websocket call get_services fails and the web UI never leaves its loading screen. dev-ha.sh installs these.
"""
import json, os, re, sys
import homeassistant

ROOT = os.path.join(os.path.dirname(homeassistant.__file__), "components")
SEED = ["ai_task", "alarm_control_panel", "assist_satellite", "calendar", "camera", "climate", "cover", "fan",
        "humidifier", "light", "lock", "media_player", "notify", "remote", "siren", "todo", "update", "vacuum",
        "water_heater", "assist_pipeline", "conversation", "frontend", "http", "config", "api", "network"]

def manifest(domain):
    try:
        with open(os.path.join(ROOT, domain, "manifest.json")) as fh:
            return json.load(fh)
    except OSError:
        return {}

seen, reqs, todo = set(), [], list(SEED)
while todo:
    d = todo.pop()
    if d in seen:
        continue
    seen.add(d)
    m = manifest(d)
    reqs.extend(m.get("requirements", []))
    todo.extend(m.get("dependencies", []))
for r in sorted(set(reqs)):
    print(r)
