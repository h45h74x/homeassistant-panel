import logging
from unittest.mock import patch

import pytest
from pytest_homeassistant_custom_component.common import MockConfigEntry

from homeassistant.exceptions import ServiceValidationError
from homeassistant.helpers import entity_registry as er
from homeassistant.setup import async_setup_component

from custom_components.panel_control.const import DOMAIN

from fake_device import FakeDevice
from test_entities import BASE, PASS, _eid, _hello_ok, setup  # noqa: F401


@pytest.fixture(autouse=True)
def _enable(enable_custom_integrations):
    pass


def _set_disabled(hass, eid, disabled):
    er.async_get(hass).async_update_entity(
        eid, disabled_by=er.RegistryEntryDisabler.USER if disabled else None)


async def test_enabling_diagnostic_changes_config_rev_and_config_endpoint(hass, setup):
    entry, dev = setup
    await _hello_ok(hass, dev)
    _, c0, _ = await dev.config()
    assert "cpu_load" not in c0["enabled"] and "cpu_load" not in c0["interval_s"]
    eid = _eid(hass, "sensor", "cpu_load")
    _set_disabled(hass, eid, False)
    await hass.async_block_till_done()
    _, c1, _ = await dev.config()
    assert "cpu_load" in c1["enabled"] and c1["interval_s"]["cpu_load"] == 60
    assert c1["config_rev"] != c0["config_rev"]
    _set_disabled(hass, eid, True)
    await hass.async_block_till_done()
    assert (await dev.config())[1]["config_rev"] == c0["config_rev"]


async def test_disabling_control_refuses_commands(hass, setup):
    entry, dev = setup
    await _hello_ok(hass, dev)
    eid = _eid(hass, "number", "brightness")
    await hass.services.async_call("number", "set_value", {"entity_id": eid, "value": 40}, blocking=True)
    _set_disabled(hass, eid, True)
    await hass.async_block_till_done()
    assert (await dev.commands())[1]["commands"] == []  # queued command purged
    assert "brightness" not in (await dev.config())[1]["enabled"]
    rt = hass.data[DOMAIN]["entries"][entry.entry_id][0]
    with pytest.raises(ValueError):
        rt.queue_command("brightness", 10)


async def test_setup_syncs_enabled_from_registry(hass, setup):
    entry, dev = setup
    await _hello_ok(hass, dev)
    _set_disabled(hass, _eid(hass, "number", "brightness"), True)
    await hass.async_block_till_done()
    assert await hass.config_entries.async_reload(entry.entry_id)
    await hass.async_block_till_done()
    status, cfg, _ = await dev.config()  # restored: no hello needed? 409 until hello
    assert status == 409
    rt = hass.data[DOMAIN]["entries"][entry.entry_id][0]
    assert "brightness" not in rt.config(rt.enabled)["enabled"]
    assert "battery_level" in rt.enabled


async def test_state_value_for_disabled_capability_is_dropped(hass, setup):
    entry, dev = setup
    await _hello_ok(hass, dev)
    _set_disabled(hass, _eid(hass, "sensor", "battery_level"), True)
    await hass.async_block_till_done()
    rt = hass.data[DOMAIN]["entries"][entry.entry_id][0]
    assert rt.apply_state({"time": 1763200000, "values": {"battery_level": 50}, "acks": []},
                          rt.enabled) == {}
    assert (await dev.state({"battery_level": 50}))[0] == 200


async def test_ack_failure_logs_warning_without_value(hass, setup, caplog):
    entry, dev = setup
    await _hello_ok(hass, dev)
    rt = hass.data[DOMAIN]["entries"][entry.entry_id][0]
    cid = rt.queue_command("brightness", 31)
    rt.take_commands()
    caplog.set_level(logging.WARNING)
    await dev.state({}, acks=[{"id": cid, "ok": True}])
    assert not [r for r in caplog.records if r.levelno >= logging.WARNING]
    err = "bad\x1b[31m\nthing" + "x" * 300
    await dev.state({}, acks=[{"id": cid, "ok": False, "error": err},
                              {"id": "zzz", "ok": False}])
    msgs = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
    assert len(msgs) == 2
    assert "kindle_test" in msgs[0] and cid in msgs[0] and "brightness" in msgs[0]
    assert "\x1b" not in msgs[0] and "\n" not in msgs[0] and msgs[0].count("x") <= 100
    assert "zzz" in msgs[1]
    text = " ".join(msgs)
    for bad in ("serial", "ssid", "192.168", ": 31"):
        assert bad not in text


async def test_corrupt_store_does_not_fail_setup(hass, hass_client_no_auth, hass_storage):
    for i, payload in enumerate([{"capabilities": "oops"}, [1, 2], {"declared": "x", "device": 3},
                                 {"declared": [{"nope": 1}, 5, {"id": "nonsense"}], "device": {"name": 5}},
                                 {"declared": [{"id": "brightness"}, {"id": "brightness"}]}]):
        did = f"k{i}"
        hass_storage[f"{DOMAIN}.{did}"] = {"version": 1, "minor_version": 1, "key": f"{DOMAIN}.{did}",
                                           "data": payload}
        e = MockConfigEntry(domain=DOMAIN, unique_id=did, data={"device_id": did, "passphrase": PASS, "name": "K"})
        e.add_to_hass(hass)
    assert await async_setup_component(hass, DOMAIN, {})
    await hass.async_block_till_done()
    client = await hass_client_no_auth()
    for i in range(5):
        d = FakeDevice(client, f"/api/panel_control/k{i}", PASS)
        assert (await d.hello())[0] == 200
