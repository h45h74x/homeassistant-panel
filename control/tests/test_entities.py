import json

import pytest
from freezegun.api import FrozenDateTimeFactory
from pytest_homeassistant_custom_component.common import MockConfigEntry, async_fire_time_changed

from homeassistant.exceptions import ServiceValidationError
from homeassistant.helpers import device_registry as dr, entity_registry as er
from homeassistant.setup import async_setup_component
from homeassistant.util import dt as dt_util

from custom_components.panel_control.const import DOMAIN

from fake_device import CONTRACT, FakeDevice

PASS = "maple-orbit-tiger-quilt-ember"
BASE = "/api/panel_control/kindle_test"


@pytest.fixture(autouse=True)
def _enable(enable_custom_integrations):
    pass


@pytest.fixture
async def setup(hass, hass_client_no_auth):
    entry = MockConfigEntry(domain=DOMAIN, unique_id="kindle_test", title="Kitchen Kindle",
                            data={"device_id": "kindle_test", "passphrase": PASS, "name": "K"})
    entry.add_to_hass(hass)
    assert await async_setup_component(hass, DOMAIN, {})
    await hass.async_block_till_done()
    client = await hass_client_no_auth()
    return entry, FakeDevice(client, BASE, PASS)


def _hello():
    return json.loads((CONTRACT / "fixtures" / "valid" / "hello-ey21.json").read_text())


def _eid(hass, kind, cap):
    return er.async_get(hass).async_get_entity_id(kind, DOMAIN, f"kindle_test_{cap}")


def _ents(hass, entry):
    return er.async_entries_for_config_entry(er.async_get(hass), entry.entry_id)


async def _hello_ok(hass, dev, hello=None):
    assert (await dev.hello(hello or "hello-ey21"))[0] == 200
    await hass.async_block_till_done()


async def test_only_declared_entities_created(hass, setup):
    entry, dev = setup
    await _hello_ok(hass, dev)
    ids = {e.unique_id for e in _ents(hass, entry)}
    assert len(ids) == 24
    assert "kindle_test_warmth" not in ids and "kindle_test_battery_temperature" not in ids


async def test_defaults_enabled_state(hass, setup):
    entry, dev = setup
    await _hello_ok(hass, dev)
    reg = er.async_get(hass)
    for cap, kind in (("brightness", "number"), ("battery_level", "sensor")):
        assert reg.async_get(_eid(hass, kind, cap)).disabled_by is None
    for cap in ("cpu_load", "ip_address"):
        assert reg.async_get(_eid(hass, "sensor", cap)).disabled_by is not None


async def test_sensor_value_from_state(hass, setup):
    entry, dev = setup
    await _hello_ok(hass, dev)
    await dev.state({"battery_level": 77, "charging": True, "brightness": 12, "keep_awake": True})
    await hass.async_block_till_done()
    assert hass.states.get(_eid(hass, "sensor", "battery_level")).state == "77"
    assert hass.states.get(_eid(hass, "binary_sensor", "charging")).state == "on"
    assert hass.states.get(_eid(hass, "number", "brightness")).state == "12"
    assert hass.states.get(_eid(hass, "switch", "keep_awake")).state == "on"


async def test_number_set_queues_command(hass, setup):
    entry, dev = setup
    await _hello_ok(hass, dev)
    await hass.services.async_call("number", "set_value", {"entity_id": _eid(hass, "number", "brightness"),
                                                           "value": 40}, blocking=True)
    cmds = (await dev.commands())[1]["commands"]
    assert [(c["capability"], c["value"]) for c in cmds] == [("brightness", 40)]


async def test_button_press_queues_value_null(hass, setup):
    entry, dev = setup
    await _hello_ok(hass, dev)
    await hass.services.async_call("button", "press", {"entity_id": _eid(hass, "button", "refresh_screen")},
                                   blocking=True)
    cmds = (await dev.commands())[1]["commands"]
    assert [(c["capability"], c["value"]) for c in cmds] == [("refresh_screen", None)]


async def test_switch_keep_awake(hass, setup):
    entry, dev = setup
    await _hello_ok(hass, dev)
    eid = _eid(hass, "switch", "keep_awake")
    await hass.services.async_call("switch", "turn_on", {"entity_id": eid}, blocking=True)
    assert (await dev.commands())[1]["commands"][0]["value"] is True
    await hass.services.async_call("switch", "turn_off", {"entity_id": eid}, blocking=True)
    assert (await dev.commands())[1]["commands"][0]["value"] is False


async def test_refuses_when_unavailable_or_disabled(hass, setup, freezer: FrozenDateTimeFactory):
    entry, dev = setup
    await _hello_ok(hass, dev)
    rt = hass.data[DOMAIN]["entries"][entry.entry_id][0]
    eid = _eid(hass, "switch", "keep_awake")
    rt.set_enabled(set())  # disabled
    with pytest.raises(ServiceValidationError):
        await hass.services.async_call("switch", "turn_on", {"entity_id": eid}, blocking=True)
    rt.set_enabled({"keep_awake"})
    freezer.tick(181)
    async_fire_time_changed(hass, dt_util.utcnow())
    await hass.async_block_till_done()
    # HA's service layer skips unavailable entities itself; either way nothing is queued
    try:
        await hass.services.async_call("switch", "turn_on", {"entity_id": eid}, blocking=True)
    except ServiceValidationError:
        pass
    assert rt.take_commands() == []


async def test_unavailable_after_missed_heartbeats(hass, setup, freezer: FrozenDateTimeFactory):
    entry, dev = setup
    await _hello_ok(hass, dev)
    eid = _eid(hass, "sensor", "battery_level")
    assert hass.states.get(eid).state != "unavailable"
    freezer.tick(181)
    async_fire_time_changed(hass, dt_util.utcnow())
    await hass.async_block_till_done()
    assert hass.states.get(eid).state == "unavailable"


async def test_restart_restores_entities_unavailable_until_hello(hass, setup):
    entry, dev = setup
    await _hello_ok(hass, dev)
    await dev.state({"battery_level": 50})
    await hass.async_block_till_done()
    assert await hass.config_entries.async_reload(entry.entry_id)
    await hass.async_block_till_done()
    eid = _eid(hass, "sensor", "battery_level")
    assert len([e for e in _ents(hass, entry)]) == 24
    assert hass.states.get(eid).state == "unavailable"
    assert (await dev.state({"battery_level": 1}))[0] == 409
    await _hello_ok(hass, dev)
    await dev.state({"battery_level": 51})
    await hass.async_block_till_done()
    assert hass.states.get(eid).state == "51"


async def test_hello_with_fewer_capabilities_marks_entities_unavailable(hass, setup):
    entry, dev = setup
    await _hello_ok(hass, dev)
    h = _hello()
    h["capabilities"] = [c for c in h["capabilities"] if c["id"] != "battery_level"]
    await _hello_ok(hass, dev, h)
    assert hass.states.get(_eid(hass, "sensor", "battery_level")).state == "unavailable"
    assert hass.states.get(_eid(hass, "switch", "keep_awake")).state != "unavailable"


async def test_device_info_from_hello(hass, setup):
    entry, dev = setup
    h = _hello()
    h["device"].update(mac="AA:BB:CC:DD:EE:FF", hw_version="rev2")
    await _hello_ok(hass, dev, h)
    d = dr.async_entries_for_config_entry(dr.async_get(hass), entry.entry_id)[0]
    assert d.name == "Kitchen Kindle" and d.manufacturer == "Amazon"
    assert d.model == "Kindle Paperwhite 1 (EY21)" and d.sw_version == "5.16.2" and d.hw_version == "rev2"
    assert (dr.CONNECTION_NETWORK_MAC, "aa:bb:cc:dd:ee:ff") in d.connections


async def test_new_capability_in_later_hello_adds_entity_no_duplicates(hass, setup):
    entry, dev = setup
    h = _hello()
    h["capabilities"] = [c for c in h["capabilities"] if c["id"] != "uptime"]
    await _hello_ok(hass, dev, h)
    assert _eid(hass, "sensor", "uptime") is None
    await _hello_ok(hass, dev)
    await _hello_ok(hass, dev)
    assert _eid(hass, "sensor", "uptime") is not None
    assert len(_ents(hass, entry)) == 24


async def test_store_never_contains_serial_ip_ssid(hass, setup, hass_storage, freezer):
    entry, dev = setup
    h = _hello()
    h["device"]["serial_number"] = "B0SERIAL123"
    await _hello_ok(hass, dev, h)
    await dev.state({"ip_address": "10.9.8.7", "ssid": "HomeNet"})
    await hass.async_block_till_done()
    data = hass_storage["panel_control.kindle_test"]["data"]
    text = json.dumps(data)
    assert "B0SERIAL123" not in text and "serial" not in text
    assert "10.9.8.7" not in text and "HomeNet" not in text
    assert data["device"]["model"] == "Kindle Paperwhite 1 (EY21)"


async def test_sleep_button_enabled_and_press_queues_null(hass, setup):
    entry, dev = setup
    await _hello_ok(hass, dev)
    eid = _eid(hass, "button", "sleep")
    assert eid is not None
    assert er.async_get(hass).async_get(eid).disabled_by is None
    for _ in range(2):
        await hass.services.async_call("button", "press", {"entity_id": eid}, blocking=True)
    cmds = (await dev.commands())[1]["commands"]
    assert [(c["capability"], c["value"]) for c in cmds] == [("sleep", None)]


async def test_sleep_press_refused_when_disabled(hass, setup):
    entry, dev = setup
    await _hello_ok(hass, dev)
    rt = hass.data[DOMAIN]["entries"][entry.entry_id][0]
    rt.set_enabled(set())
    with pytest.raises(ServiceValidationError):
        await hass.services.async_call("button", "press", {"entity_id": _eid(hass, "button", "sleep")},
                                       blocking=True)
    assert (await dev.commands())[1]["commands"] == []


async def test_sleep_entity_only_when_declared(hass, setup):
    entry, dev = setup
    h = _hello()
    h["capabilities"] = [c for c in h["capabilities"] if c["id"] != "sleep"]
    await _hello_ok(hass, dev, h)
    assert _eid(hass, "button", "sleep") is None
