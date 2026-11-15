"""Shared entity base and platform setup helper.

Device info from the hello (`runtime.device`, never the serial number) lives on the runtime.
"""
from __future__ import annotations

from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant, callback
from homeassistant.exceptions import ServiceValidationError
from homeassistant.helpers.device_registry import CONNECTION_NETWORK_MAC, DeviceInfo
from homeassistant.helpers.dispatcher import async_dispatcher_connect
from homeassistant.helpers.entity import Entity, EntityCategory

from .const import DOMAIN, hello_signal
from .enablement import default_enabled
from .mapping import NAME_OVERRIDE, platform_for
from .runtime import CATALOG, DeviceRuntime
from .views import signal as state_signal

_ACRONYMS = {"cpu", "ssid", "ip", "mac"}


def label(cap_id: str) -> str:
    words = [w.upper() if w in _ACRONYMS else w for w in cap_id.split("_")]
    s = " ".join(words)
    return s[0].upper() + s[1:]


def device_info(entry: ConfigEntry, rt: DeviceRuntime) -> DeviceInfo:
    d = rt.device
    info = DeviceInfo(identifiers={(DOMAIN, rt.device_id)}, name=entry.title)
    for k in ("manufacturer", "model", "sw_version", "hw_version"):
        if k in d:
            info[k] = d[k]
    if "mac" in d:
        info["connections"] = {(CONNECTION_NETWORK_MAC, d["mac"])}
    return info


class PanelEntity(Entity):
    _attr_should_poll = False
    _attr_has_entity_name = True

    def __init__(self, entry: ConfigEntry, rt: DeviceRuntime, cap: str) -> None:
        self._entry, self._rt, self._cap = entry, rt, cap
        self._value = None
        c = CATALOG[cap]
        self._attr_unique_id = f"{rt.device_id}_{cap}"
        self._attr_name = NAME_OVERRIDE.get(cap) or label(cap)
        self._attr_entity_registry_enabled_default = default_enabled(cap)
        if c["category"] == "diagnostic":
            self._attr_entity_category = EntityCategory.DIAGNOSTIC

    @property
    def device_info(self) -> DeviceInfo:
        return device_info(self._entry, self._rt)

    @property
    def available(self) -> bool:
        return self._rt.available() and self._cap in self._rt.declared

    async def async_added_to_hass(self) -> None:
        for sig, cb in ((state_signal(self._rt.device_id), self._on_state),
                        (hello_signal(self._rt.device_id), self._on_hello)):
            self.async_on_remove(async_dispatcher_connect(self.hass, sig, cb))

    @callback
    def _on_state(self, values: dict) -> None:
        if self._cap in values:
            self._value = values[self._cap]
        self.async_write_ha_state()

    @callback
    def _on_hello(self) -> None:
        self.async_write_ha_state()

    def _queue(self, value) -> None:
        if not self.available:
            raise ServiceValidationError(f"{self.name} is unavailable: the device is not connected")
        try:
            self._rt.queue_command(self._cap, value)
        except ValueError as err:
            raise ServiceValidationError(f"Cannot set {self.name}: {err}") from err


@callback
def setup_kind(hass: HomeAssistant, entry: ConfigEntry, add, kind: str, factory) -> None:
    """Add entities of one platform for declared capabilities now and after later hellos."""
    rt = hass.data[DOMAIN]["entries"][entry.entry_id][0]
    added: set[str] = set()

    @callback
    def _add() -> None:
        new = [c for c in rt.declared if platform_for(c, CATALOG[c]["entity"]) == kind and c not in added]
        added.update(new)
        if new:
            add([factory(entry, rt, c) for c in new])

    _add()
    entry.async_on_unload(async_dispatcher_connect(hass, hello_signal(rt.device_id), _add))
