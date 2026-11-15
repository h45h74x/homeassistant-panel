import logging
from unittest.mock import patch

import pytest
from pytest_homeassistant_custom_component.common import MockConfigEntry

from homeassistant.exceptions import ServiceValidationError
from homeassistant.helpers import entity_registry as er
from homeassistant.setup import async_setup_component

from custom_components.panel_control.const import DOMAIN

from fake_device import FakeDevice
from test_entities import BASE, PASS, _eid, _hello_ok, setup, setup_pre  # noqa: F401


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
    eid = _eid(hass, "light", "brightness")
    await hass.services.async_call("light", "turn_on", {"entity_id": eid, "brightness": 102}, blocking=True)
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
    _set_disabled(hass, _eid(hass, "light", "brightness"), True)
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


async def _boot(hass, hass_client_no_auth, hass_storage, did, stored):
    hass_storage[f"{DOMAIN}.{did}"] = stored
    MockConfigEntry(domain=DOMAIN, unique_id=did, data={"device_id": did, "passphrase": PASS,
                                                        "name": "K"}).add_to_hass(hass)
    assert await async_setup_component(hass, DOMAIN, {})
    await hass.async_block_till_done()
    return FakeDevice(await hass_client_no_auth(), f"/api/panel_control/{did}", PASS)


@pytest.mark.parametrize("ver", [(99, 1), (1, 99), (0, 0)])
async def test_store_version_mismatch_does_not_fail_setup(hass, hass_client_no_auth, hass_storage, ver):
    d = await _boot(hass, hass_client_no_auth, hass_storage, "kv", {
        "version": ver[0], "minor_version": ver[1], "key": f"{DOMAIN}.kv",
        "data": {"declared": [{"id": "brightness"}], "device": {"name": "x"}}})
    assert (await d.hello())[0] == 200


@pytest.mark.parametrize("bad", [{"min": "x"}, {"max": [1]}, {"max": float("nan")}, {"min": float("inf")},
                                 {"max": True}, {"min": 50, "max": 10}])
async def test_stored_bad_bounds_are_ignored(hass, hass_client_no_auth, hass_storage, bad):
    d = await _boot(hass, hass_client_no_auth, hass_storage, "kb", {
        "version": 1, "minor_version": 1, "key": f"{DOMAIN}.kb",
        "data": {"declared": [{"id": "brightness", **bad}, {"id": "battery_level"}, {"id": "zzz"}, {"id": "ssid", "min": "q"}],
                 "device": {}}})
    rt = hass.data[DOMAIN]["entries"][next(iter(hass.data[DOMAIN]["entries"]))][0]
    assert set(rt.declared) >= {"brightness", "battery_level"} and "zzz" not in rt.declared
    rt.config(rt.enabled)
    ids = {e.unique_id for e in er.async_entries_for_config_entry(
        er.async_get(hass), hass.config_entries.async_entries(DOMAIN)[0].entry_id)}
    assert "kb_brightness" in ids and "kb_battery_level" in ids
    assert (await d.hello())[0] == 200


async def test_ack_logging_never_breaks_apply_state(hass, setup, caplog):
    entry, dev = setup
    await _hello_ok(hass, dev)
    rt = hass.data[DOMAIN]["entries"][entry.entry_id][0]
    caplog.set_level(logging.WARNING)
    acks = [{"id": "a", "ok": False, "error": e} for e in (None, 5, ["x"], {"k": 1}, "y" * 10000, "a b c")]
    acks.append({"id": "i\n\x1b[31m" + "d" * 100, "ok": False})
    rt.apply_state({"time": 1763200000, "values": {}, "acks": acks}, rt.enabled)
    msgs = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
    assert len(msgs) == 6  # 5 shown plus a summary
    for m in msgs:
        assert not any(c in m for c in "\n\x1b  ") and len(m) < 250


@pytest.mark.parametrize("bad_id", [["x"], {}, {"a": 1}])
async def test_stored_unhashable_id_is_dropped(hass, hass_client_no_auth, hass_storage, bad_id):
    d = await _boot(hass, hass_client_no_auth, hass_storage, "ku", {
        "version": 1, "minor_version": 1, "key": f"{DOMAIN}.ku",
        "data": {"declared": [{"id": bad_id}, {"id": "brightness"}], "device": {}}})
    assert (await d.hello())[0] == 200


@pytest.mark.parametrize("bad_id", [["x"], {"a": 1}])
async def test_ack_unhashable_id_does_not_raise(hass, setup, bad_id):
    entry, dev = setup
    await _hello_ok(hass, dev)
    rt = hass.data[DOMAIN]["entries"][entry.entry_id][0]
    rt.apply_state({"time": 1763200000, "values": {}, "acks": [{"id": bad_id, "ok": False}]}, rt.enabled)


@pytest.mark.parametrize("cap,bad", [("battery_level", "abc"), ("battery_level", True), ("charging", "yes"),
                                     ("charging", 1), ("ssid", 5), ("power_state", "bogus"),
                                     ("power_state", 3), ("battery_level", None)])
async def test_state_value_type_mismatch_is_null(hass, setup, cap, bad):
    entry, dev = setup
    await _hello_ok(hass, dev)
    rt = hass.data[DOMAIN]["entries"][entry.entry_id][0]
    rt.set_enabled(set(rt.declared))
    out = rt.apply_state({"time": 1763200000, "values": {cap: bad, "uptime": 5}, "acks": []}, rt.enabled)
    assert out[cap] is None and out["uptime"] == 5


async def test_state_value_valid_types_kept(hass, setup):
    entry, dev = setup
    await _hello_ok(hass, dev)
    rt = hass.data[DOMAIN]["entries"][entry.entry_id][0]
    rt.set_enabled(set(rt.declared))
    v = {"battery_level": 5.5, "charging": False, "power_state": "active", "ssid": "x"}
    assert rt.apply_state({"time": 1763200000, "values": v, "acks": []}, rt.enabled).items() >= v.items()


async def test_mismatched_value_gives_unknown_entity(hass, setup):
    entry, dev = setup
    await _hello_ok(hass, dev)
    assert (await dev.state({"battery_level": "abc"}))[0] == 200
    await hass.async_block_till_done()
    assert hass.states.get(_eid(hass, "sensor", "battery_level")).state == "unknown"


async def test_failed_ack_warnings_capped(hass, setup, caplog):
    entry, dev = setup
    await _hello_ok(hass, dev)
    rt = hass.data[DOMAIN]["entries"][entry.entry_id][0]
    caplog.set_level(logging.WARNING)
    acks = [{"id": f"a{i}", "ok": False} for i in range(20)]
    rt.apply_state({"time": 1763200000, "values": {}, "acks": acks}, rt.enabled)
    msgs = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
    assert len(msgs) == 6 and "15" in msgs[-1]


async def test_unload_wakes_waiting_poll(hass, setup):
    import asyncio
    entry, dev = setup
    await _hello_ok(hass, dev)
    task = asyncio.create_task(dev.commands(wait=30))
    await asyncio.sleep(0.2)
    assert await hass.config_entries.async_unload(entry.entry_id)
    status, body, _ = await asyncio.wait_for(task, 2)
    assert body.get("commands", []) == [] or status != 200


async def test_failed_setup_leaves_no_runtime(hass):
    entry = MockConfigEntry(domain=DOMAIN, unique_id="kf", data={"device_id": "kf", "passphrase": PASS, "name": "K"})
    entry.add_to_hass(hass)
    with patch("homeassistant.config_entries.ConfigEntries.async_forward_entry_setups",
               side_effect=RuntimeError("boom")):
        assert await async_setup_component(hass, DOMAIN, {})
        await hass.async_block_till_done()
    assert entry.entry_id not in hass.data[DOMAIN]["entries"]


async def test_enabling_light_restores_brightness_in_config(hass, setup):
    entry, dev = setup
    await _hello_ok(hass, dev)
    eid = _eid(hass, "light", "brightness")
    _set_disabled(hass, eid, True)
    await hass.async_block_till_done()
    assert "brightness" not in (await dev.config())[1]["enabled"]
    _set_disabled(hass, eid, False)
    await hass.async_block_till_done()
    assert "brightness" in (await dev.config())[1]["enabled"]
