"""Talks to the interim dev Home Assistant (control/dev-ha.sh): pair a device, list entities.

  dev_ha.py pair [NAME]   add the integration, print the Kindle config lines (url=..., token=...)
  dev_ha.py states        list panel_control entity states (value masked for sensitive ids)
  dev_ha.py call DOMAIN.SERVICE '{"entity_id": "...", ...}'   call a service (e.g. number.set_value)
  dev_ha.py check         verify the websocket calls the web UI needs at startup (get_services, get_config, get_states)
  dev_ha.py enable|disable NAME...   enable/disable entities of the integration whose id contains NAME (websocket API)
Reads the admin password from .dev-ha/.admin-pass. Stdlib only.
"""
import json, os, sys, urllib.error, urllib.parse, urllib.request

BASE = "http://127.0.0.1:%s" % os.environ.get("DEV_HA_PORT", "8123")
CID = BASE + "/"
PASSFILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".dev-ha", ".admin-pass")
SENSITIVE = ("ip_address", "ssid", "mac_address")


def call(path, data=None, token=None, form=False):
    headers = {}
    if token:
        headers["Authorization"] = "Bearer " + token
    body = None
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            body = json.dumps(data).encode()
            headers["Content-Type"] = "application/json"
    req = urllib.request.Request(BASE + path, body, headers)
    try:
        return json.loads(urllib.request.urlopen(req, timeout=30).read() or "null")
    except urllib.error.HTTPError as err:
        sys.exit("HA answered %s for %s: %s" % (err.code, path, err.read()[:300].decode(errors="replace")))
    except urllib.error.URLError as err:
        sys.exit("dev HA not reachable at %s (%s). Run: sh control/dev-ha.sh start" % (BASE, err.reason))


def login():
    password = open(PASSFILE).read().strip()
    flow = call("/auth/login_flow", {"client_id": CID, "handler": ["homeassistant", None],
                                     "redirect_uri": CID + "?auth_callback=1"})
    res = call("/auth/login_flow/" + flow["flow_id"], {"username": "admin", "password": password, "client_id": CID})
    if res.get("type") != "create_entry":
        sys.exit("login failed: %s" % res.get("errors"))
    return call("/auth/token", {"grant_type": "authorization_code", "code": res["result"], "client_id": CID},
                form=True)["access_token"]


def pair(name):
    tok = login()
    flow = call("/api/config/config_entries/flow", {"handler": "panel_control", "show_advanced_options": False}, tok)
    flow = call("/api/config/config_entries/flow/" + flow["flow_id"], {"name": name}, tok)
    if flow.get("step_id") != "pairing":
        sys.exit("unexpected flow step: %r" % flow)
    ph = flow["description_placeholders"]
    done = call("/api/config/config_entries/flow/" + flow["flow_id"], {}, tok)
    if done.get("type") != "create_entry":
        sys.exit("pairing did not create an entry: %r" % done)
    if ph.get("url_note"):
        print("# note: " + ph["url_note"], file=sys.stderr)
    print("url=" + ph["url"])
    print("token=" + ph["passphrase"])


def states():
    tok = login()
    rows = [s for s in call("/api/states", token=tok) if "panel_control" in json.dumps(s.get("attributes", {})) or True]
    ent = call("/api/config/entity_registry/list", token=tok) if False else None  # websocket only; filter by name below
    shown = 0
    for s in sorted(rows, key=lambda x: x["entity_id"]):
        eid = s["entity_id"]
        if not (eid.split(".", 1)[1].startswith(os.environ.get("DEV_HA_PREFIX", "kindle"))):
            continue
        val = s["state"]
        if any(k in eid for k in SENSITIVE):
            val = "<masked>"
        print("%-48s %s" % (eid, val))
        shown += 1
    if not shown:
        print("(no entities with prefix %r yet)" % os.environ.get("DEV_HA_PREFIX", "kindle"))


def call_service(target, payload):
    tok = login()
    domain, service = target.split(".", 1)
    out = call("/api/services/%s/%s" % (domain, service), json.loads(payload or "{}"), tok)
    print("ok" if out is not None else "ok (no state change returned)")


def set_disabled(names, disable):
    import asyncio
    import aiohttp

    async def run():
        tok = login()
        async with aiohttp.ClientSession() as sess:
            async with sess.ws_connect(BASE.replace("http", "ws") + "/api/websocket") as ws:
                await ws.receive_json()
                await ws.send_json({"type": "auth", "access_token": tok})
                if (await ws.receive_json())["type"] != "auth_ok":
                    sys.exit("websocket auth failed")
                await ws.send_json({"id": 1, "type": "config/entity_registry/list"})
                reg = (await ws.receive_json())["result"]
                mine = [e for e in reg if e.get("platform") == "panel_control"]
                n = 1
                for e in mine:
                    if not any(x in e["entity_id"] for x in names):
                        continue
                    n += 1
                    await ws.send_json({"id": n, "type": "config/entity_registry/update", "entity_id": e["entity_id"],
                                        "disabled_by": "user" if disable else None})
                    res = await ws.receive_json()
                    print("%s %s: %s" % ("disabled" if disable else "enabled", e["entity_id"], "ok" if res.get("success") else res))
                if n == 1:
                    print("no matching panel_control entities for %r" % names)
    asyncio.run(run())


def check():
    """The web UI stays on its loading screen forever if get_services fails (missing requirements, see dev_ha_deps.py)."""
    import asyncio
    import aiohttp

    async def run():
        tok = login()
        bad = []
        async with aiohttp.ClientSession() as sess:
            async with sess.ws_connect(BASE.replace("http", "ws") + "/api/websocket") as ws:
                await ws.receive_json()
                await ws.send_json({"type": "auth", "access_token": tok})
                if (await ws.receive_json())["type"] != "auth_ok":
                    sys.exit("websocket auth failed")
                for i, cmd in enumerate(("get_services", "get_config", "get_states", "get_panels"), 1):
                    await ws.send_json({"id": i, "type": cmd})
                    res = await asyncio.wait_for(ws.receive_json(), 15)
                    if not res.get("success"):
                        bad.append("%s: %s" % (cmd, res.get("error")))
        if bad:
            sys.exit("web UI backend NOT ok (the page would load forever): " + "; ".join(bad))
        print("web UI backend ok")
    asyncio.run(run())


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "pair":
        pair(sys.argv[2] if len(sys.argv) > 2 else "Kindle")
    elif cmd == "states":
        states()
    elif cmd == "check":
        check()
    elif cmd == "call" and len(sys.argv) >= 3:
        call_service(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "{}")
    elif cmd in ("enable", "disable") and len(sys.argv) >= 3:
        set_disabled(sys.argv[2:], cmd == "disable")
    else:
        sys.exit(__doc__)
