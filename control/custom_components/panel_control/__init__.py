"""Panel Control integration."""
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant

from .const import DOMAIN
from .enablement import default_enabled
from .lockout import Lockout
from .runtime import DeviceRuntime
from .views import CommandsView, ConfigView, HelloView, StateView


async def async_setup(hass: HomeAssistant, config: dict) -> bool:
    hass.data.setdefault(DOMAIN, {"lockout": Lockout(), "entries": {}})
    for view in (HelloView, StateView, CommandsView, ConfigView):
        hass.http.register_view(view())
    return True


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    rt = DeviceRuntime(entry.data["device_id"], default_enabled)
    rt.restore([])  # no hello yet: state/commands/config answer 409 until one arrives
    hass.data[DOMAIN]["entries"][entry.entry_id] = (rt, entry.data["passphrase"])
    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    hass.data[DOMAIN]["entries"].pop(entry.entry_id, None)
    return True
