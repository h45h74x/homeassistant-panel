"""Which declared capabilities are enabled: the entity registry decides, the catalog default is the fallback."""
from homeassistant.core import HomeAssistant
from homeassistant.helpers import entity_registry as er

from .const import DOMAIN
from .runtime import CATALOG, DeviceRuntime


def default_enabled(cap_id: str) -> bool:
    c = CATALOG[cap_id]
    return c["category"] in ("control", "sensor") and not c["sensitive"]


def compute_enabled(hass: HomeAssistant, entry_id: str, runtime: DeviceRuntime) -> set[str]:
    reg = er.async_get(hass)
    out = set()
    for cap in runtime.declared:
        entity_id = reg.async_get_entity_id(
            CATALOG[cap]["entity"], DOMAIN, f"{runtime.device_id}_{cap}")
        entry = reg.async_get(entity_id) if entity_id else None
        if (entry.disabled_by is None) if entry else default_enabled(cap):
            out.add(cap)
    return out
