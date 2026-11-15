from homeassistant.helpers import entity_registry as er
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.panel_control.const import DOMAIN
from custom_components.panel_control.enablement import compute_enabled, default_enabled
from custom_components.panel_control.runtime import DeviceRuntime


def _rt(*ids):
    rt = DeviceRuntime("kindle_test", default_enabled)
    rt.apply_hello({"capabilities": [{"id": i} for i in ids]})
    return rt


def test_defaults():
    assert default_enabled("brightness") and default_enabled("battery_level")
    assert not default_enabled("ssid")  # sensitive


async def test_registry_disabled_excluded(hass):
    entry = MockConfigEntry(domain=DOMAIN)
    entry.add_to_hass(hass)
    er.async_get(hass).async_get_or_create(
        "sensor", DOMAIN, "kindle_test_battery_level", config_entry=entry,
        disabled_by=er.RegistryEntryDisabler.USER)
    er.async_get(hass).async_get_or_create(
        "sensor", DOMAIN, "kindle_test_ssid", config_entry=entry)  # user enabled a sensitive one
    rt = _rt("battery_level", "ssid", "brightness")
    assert compute_enabled(hass, entry.entry_id, rt) == {"ssid", "brightness"}


async def test_unregistered_falls_back_to_default(hass):
    assert compute_enabled(hass, "x", _rt("brightness", "ip_address")) == {"brightness"}


async def test_capability_added_in_second_hello_enabled(hass):
    rt = _rt("brightness")
    rt.set_enabled(compute_enabled(hass, "x", rt))
    rt.apply_hello({"capabilities": [{"id": "brightness"}, {"id": "warmth"}]})
    assert "warmth" not in rt.enabled
    rt.set_enabled(compute_enabled(hass, "x", rt))
    assert rt.enabled == {"brightness", "warmth"}


async def test_brightness_looked_up_as_light(hass):
    entry = MockConfigEntry(domain=DOMAIN)
    entry.add_to_hass(hass)
    er.async_get(hass).async_get_or_create(
        "light", DOMAIN, "kindle_test_brightness", config_entry=entry,
        disabled_by=er.RegistryEntryDisabler.USER)
    assert compute_enabled(hass, entry.entry_id, _rt("brightness", "battery_level")) == {"battery_level"}
