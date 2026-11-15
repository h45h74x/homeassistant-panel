"""Contract HTTP views. HA auth is bypassed on purpose: the bearer passphrase is checked instead.

Check order: lockout (by socket peer, never X-Forwarded-For), unknown device, token,
then hello_required / unsupported_contract, then body validation.
"""
from __future__ import annotations

import json
import math

from aiohttp import web
from homeassistant.components.http import HomeAssistantView
from homeassistant.helpers.dispatcher import async_dispatcher_send

from . import passphrase as pp
from .const import DOMAIN
from .enablement import compute_enabled
from .runtime import CATALOG

MAX_WAIT_S = 55
HEARTBEAT_S = 60
POLL_WAIT_S = 25
_DEVICE_REQ = ("name", "manufacturer", "model", "sw_version")
_DEVICE_OPT = ("hw_version", "mac", "serial_number")


def signal(device_id: str) -> str:
    return f"{DOMAIN}_state_{device_id}"


def _dump(body, status=200) -> web.Response:
    return web.Response(text=json.dumps(body, separators=(",", ":")),
                        content_type="application/json", status=status)


def _err(status: int, code: str, detail: str | None = None) -> web.Response:
    body = {"error": code}
    if detail:
        body["detail"] = detail
    return _dump(body, status)


MAX_TIME = 4102444800  # year 2100


def _num(v) -> bool:
    if isinstance(v, bool):
        return False
    if isinstance(v, int):
        try:
            float(v)  # must be float-convertible: later HA/entity code calls float()
        except OverflowError:
            return False
        return True
    return isinstance(v, float) and math.isfinite(v)


def _keys_ok(d, required, optional=()) -> bool:
    return isinstance(d, dict) and set(required) <= set(d) <= set(required) | set(optional)


def _validate_hello(b) -> str | None:
    if not _keys_ok(b, ("contract", "agent_version", "device", "capabilities")):
        return "bad hello shape"
    if not isinstance(b["agent_version"], str):
        return "agent_version"
    d = b["device"]
    if not _keys_ok(d, _DEVICE_REQ, _DEVICE_OPT) or not all(isinstance(v, str) for v in d.values()):
        return "bad device"
    caps = b["capabilities"]
    if not isinstance(caps, list):
        return "capabilities"
    seen = set()
    for c in caps:
        if not _keys_ok(c, ("id",), ("min", "max")):
            return "bad capability"
        if not isinstance(c["id"], str) or c["id"] not in CATALOG or c["id"] in seen:
            return "unknown or duplicate capability"
        seen.add(c["id"])
        if not all(_num(c[k]) for k in ("min", "max") if k in c):
            return "bad min/max"
    return None


def _validate_state(b) -> str | None:
    if not _keys_ok(b, ("time", "values", "acks")):
        return "bad state shape"
    if isinstance(b["time"], bool) or not isinstance(b["time"], int) or not 0 <= b["time"] <= MAX_TIME:
        return "time"
    if not isinstance(b["values"], dict):
        return "values"
    for k, v in b["values"].items():
        if k not in CATALOG:
            return f"unknown capability {k}"
        if v is not None and not isinstance(v, (bool, str)) and not _num(v):
            return f"bad value for {k}"
    if not isinstance(b["acks"], list):
        return "acks"
    for a in b["acks"]:
        if not _keys_ok(a, ("id", "ok"), ("error",)) or not isinstance(a["id"], str) \
                or not isinstance(a["ok"], bool) or not isinstance(a.get("error", ""), str):
            return "bad ack"
    return None


class _Base(HomeAssistantView):
    requires_auth = False

    def _auth(self, request: web.Request, device_id: str):
        """Return (entry_id, runtime) or an error response.

        The lockout key is request.remote (the socket peer), never X-Forwarded-For; behind a
        reverse proxy HA's own forwarded-header middleware decides what request.remote is.
        """
        hass = request.app["hass"]
        data = hass.data.get(DOMAIN, {})
        lockout, ip = data.get("lockout"), request.remote
        if lockout and lockout.is_locked(ip):
            return _err(429, "locked_out")
        found = next(((eid, rt, stored) for eid, (rt, stored) in data.get("entries", {}).items()
                      if rt.device_id == device_id), None)
        if found is None:
            return _err(404, "unknown_device")
        eid, rt, stored = found
        h = request.headers.get("Authorization", "")
        scheme, _, token = h.partition(" ")
        if scheme.lower() != "bearer" or not token.strip() or not pp.matches(stored, token):
            lockout.record_failure(ip)
            return _err(401, "unauthorized")
        lockout.record_success(ip)
        rt.touch()
        return eid, rt

    def _gate(self, request, device_id):
        """Auth plus the hello_required check for state/commands/config."""
        a = self._auth(request, device_id)
        if isinstance(a, web.Response):
            return a
        if a[1].needs_hello:
            return _err(409, "hello_required")
        return a

    @staticmethod
    async def _json(request):
        try:
            return await request.json()
        except Exception:  # noqa: BLE001 - any parse failure is invalid_payload
            return None


class HelloView(_Base):
    url = "/api/panel_control/{device_id}/hello"
    name = "api:panel_control:hello"

    async def post(self, request, device_id):
        a = self._auth(request, device_id)
        if isinstance(a, web.Response):
            return a
        eid, rt = a
        body = await self._json(request)
        if isinstance(body, dict) and "contract" in body and not (
                type(body["contract"]) is int and body["contract"] == 1):
            return _err(400, "unsupported_contract")
        if (bad := _validate_hello(body)) is not None:
            return _err(400, "invalid_payload", bad)
        rt.apply_hello(body)
        rt.set_enabled(compute_enabled(request.app["hass"], eid, rt))
        return _dump({"contract": 1, "heartbeat_s": HEARTBEAT_S, "poll_wait_s": POLL_WAIT_S,
                      "config": rt.config(rt.enabled)})


class StateView(_Base):
    url = "/api/panel_control/{device_id}/state"
    name = "api:panel_control:state"

    async def post(self, request, device_id):
        a = self._gate(request, device_id)
        if isinstance(a, web.Response):
            return a
        _, rt = a
        body = await self._json(request)
        if (bad := _validate_state(body)) is not None:
            return _err(400, "invalid_payload", bad)
        values = rt.apply_state(body, rt.enabled)
        async_dispatcher_send(request.app["hass"], signal(device_id), values)
        return _dump({"config_rev": rt.config(rt.enabled)["config_rev"]})


class CommandsView(_Base):
    url = "/api/panel_control/{device_id}/commands"
    name = "api:panel_control:commands"

    async def get(self, request, device_id):
        a = self._gate(request, device_id)
        if isinstance(a, web.Response):
            return a
        _, rt = a
        try:
            wait = float(request.query.get("wait", 0))
        except ValueError:
            wait = 0
        wait = min(wait, MAX_WAIT_S) if math.isfinite(wait) and wait > 0 else 0
        cmds = await rt.wait_commands(wait)
        rt.touch()
        return _dump({"config_rev": rt.config(rt.enabled)["config_rev"], "commands": [
            {"id": c["id"], "capability": c["capability"], "value": c["value"],
             "issued_at": c["issued_at"]} for c in cmds]})


class ConfigView(_Base):
    url = "/api/panel_control/{device_id}/config"
    name = "api:panel_control:config"

    async def get(self, request, device_id):
        a = self._gate(request, device_id)
        if isinstance(a, web.Response):
            return a
        c = a[1].config(a[1].enabled)
        return _dump({"config_rev": c["config_rev"], "enabled": c["enabled"],
                      "interval_s": c["interval_s"]})
