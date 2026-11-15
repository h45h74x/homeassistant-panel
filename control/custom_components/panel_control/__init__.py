"""Panel Control integration.

Persistence: one Store per entry (`panel_control.<device_id>`) holds the declared
capabilities and the hello device block (without serial_number), so entities exist
(unavailable) after a restart until the device sends hello again.
"""
from datetime import timedelta

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import Event, HomeAssistant, callback
from homeassistant.helpers import device_registry as dr, entity_registry as er
from homeassistant.helpers.dispatcher import async_dispatcher_connect, async_dispatcher_send
from homeassistant.helpers.event import async_track_time_interval
from homeassistant.helpers.storage import Store

from .const import DOMAIN, hello_signal
from .enablement import compute_enabled, default_enabled
from .entity import device_info
from .lockout import Lockout
from .runtime import CATALOG, DeviceRuntime
from .views import CommandsView, ConfigView, HEARTBEAT_S, HelloView, StateView
from .views import signal as state_signal

PLATFORMS = ["number", "switch", "button", "sensor", "binary_sensor"]
_SAFE_DEVICE = ("name", "manufacturer", "model", "sw_version", "hw_version", "mac")


def _store(hass: HomeAssistant, device_id: str) -> Store:
    return Store(hass, 1, f"{DOMAIN}.{device_id}")


async def async_setup(hass: HomeAssistant, config: dict) -> bool:
    hass.data.setdefault(DOMAIN, {"lockout": Lockout(), "entries": {}})
    for view in (HelloView, StateView, CommandsView, ConfigView):
        hass.http.register_view(view())
    return True


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    device_id = entry.data["device_id"]
    store = _store(hass, device_id)
    saved = await store.async_load()
    if not isinstance(saved, dict):
        saved = {}
    caps = saved.get("declared")
    caps = [c for c in caps if isinstance(c, dict) and c.get("id") in CATALOG] \
        if isinstance(caps, list) else []
    dev = saved.get("device")
    dev = {k: v for k, v in dev.items() if k in _SAFE_DEVICE and isinstance(v, str)} \
        if isinstance(dev, dict) else {}
    rt = DeviceRuntime(device_id, default_enabled)
    # no hello yet: state/commands/config answer 409 until one arrives
    try:
        rt.restore(caps, dev)
    except (ValueError, TypeError, KeyError):  # e.g. duplicate ids or bad min/max in a corrupt store
        rt.restore([], {})
    hass.data[DOMAIN]["entries"][entry.entry_id] = (rt, entry.data["passphrase"])
    entry.async_on_unload(entry.add_update_listener(_reload))  # new passphrase takes effect at once

    def sync_device() -> None:
        dr.async_get(hass).async_get_or_create(config_entry_id=entry.entry_id,
                                               **device_info(entry, rt))

    async def on_hello() -> None:
        sync_device()
        await store.async_save({"declared": list(rt.declared.values()), "device": rt.device})

    @callback
    def tick(_now) -> None:
        async_dispatcher_send(hass, state_signal(device_id), {})

    sync_device()
    entry.async_on_unload(async_dispatcher_connect(hass, hello_signal(device_id), on_hello))
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)

    @callback
    def sync_enabled() -> None:
        rt.set_enabled(compute_enabled(hass, entry.entry_id, rt))

    @callback
    def on_registry(event: Event) -> None:
        if event.data["action"] == "remove":  # entry already gone, cannot tell whose it was
            return sync_enabled()
        e = er.async_get(hass).async_get(event.data["entity_id"])
        if e and e.platform == DOMAIN and e.unique_id.startswith(f"{device_id}_"):
            sync_enabled()

    sync_enabled()
    entry.async_on_unload(hass.bus.async_listen(er.EVENT_ENTITY_REGISTRY_UPDATED, on_registry))
    # entities re-check availability, so they go unavailable after 3 missed heartbeats
    entry.async_on_unload(async_track_time_interval(
        hass, tick, timedelta(seconds=HEARTBEAT_S)))
    return True


async def _reload(hass: HomeAssistant, entry: ConfigEntry) -> None:
    await hass.config_entries.async_reload(entry.entry_id)


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    ok = await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
    if ok:
        hass.data[DOMAIN]["entries"].pop(entry.entry_id, None)
    return ok


async def async_remove_entry(hass: HomeAssistant, entry: ConfigEntry) -> None:
    await _store(hass, entry.data["device_id"]).async_remove()
