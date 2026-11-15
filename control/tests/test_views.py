import asyncio
import json
from unittest.mock import patch

import pytest
from pytest_homeassistant_custom_component.common import MockConfigEntry

from homeassistant.setup import async_setup_component

from custom_components.panel_control import async_setup_entry, views
from custom_components.panel_control.const import DOMAIN

from fake_device import CONTRACT, FakeDevice

PASS = "maple-orbit-tiger-quilt-ember"
BASE = "/api/panel_control/kindle_test"


@pytest.fixture(autouse=True)
def _enable(enable_custom_integrations):
    pass


@pytest.fixture
async def setup(hass, hass_client_no_auth):
    entry = MockConfigEntry(domain=DOMAIN, unique_id="kindle_test",
                            data={"device_id": "kindle_test", "passphrase": PASS, "name": "K"})
    entry.add_to_hass(hass)
    # config_flow.py arrives in Task 5, so drive setup directly instead of through the entry manager
    assert await async_setup_component(hass, DOMAIN, {})
    assert await async_setup_entry(hass, entry)
    client = await hass_client_no_auth()
    rt = hass.data[DOMAIN]["entries"][entry.entry_id][0]
    return client, FakeDevice(client, BASE, PASS), rt


async def test_hello_ok_returns_config(setup):
    _, dev, rt = setup
    status, body, _ = await dev.hello()
    assert status == 200 and body["contract"] == 1
    assert "brightness" in body["config"]["enabled"] and "ssid" not in body["config"]["enabled"]


async def test_wrong_token_401_then_lockout_429(setup):
    client, dev, _ = setup
    bad = FakeDevice(client, BASE, "nope")
    for _ in range(10):
        assert (await bad.hello())[0] == 401
    assert (await bad.hello())[0] == 429


async def test_token_normalization_accepted(setup):
    client, _, _ = setup
    for tok in (PASS.upper(), PASS.replace("-", " "), f"  {PASS} "):
        assert (await FakeDevice(client, BASE, tok).hello())[0] == 200


async def test_missing_header_401(setup):
    client, _, _ = setup
    assert (await client.post(f"{BASE}/hello", json={})).status == 401


async def test_unknown_device_404(setup):
    client, _, _ = setup
    assert (await FakeDevice(client, "/api/panel_control/nope", PASS).hello())[0] == 404


async def test_invalid_payload_400(setup):
    _, dev, _ = setup
    h = json.loads((CONTRACT / "fixtures/invalid/hello-lock-capability.json").read_text())
    status, body, _ = await dev.hello(h)
    assert (status, body["error"]) == (400, "invalid_payload")


async def test_unsupported_contract_400(setup):
    _, dev, _ = setup
    status, body, _ = await dev.hello({"contract": 2})
    assert (status, body["error"]) == (400, "unsupported_contract")


async def test_state_before_hello_409(setup):
    status, body, _ = await setup[1].state({})
    assert (status, body["error"]) == (409, "hello_required")


async def test_commands_before_hello_409(setup):
    assert (await setup[1].commands())[0] == 409


async def test_config_before_hello_409(setup):
    assert (await setup[1].config())[0] == 409


async def test_state_updates_and_returns_config_rev(setup):
    _, dev, _ = setup
    _, h, _ = await dev.hello()
    status, body, _ = await dev.state({"battery_level": 80})
    assert status == 200 and body["config_rev"] == h["config"]["config_rev"]


async def test_state_malformed_ack_400(setup):
    _, dev, _ = setup
    await dev.hello()
    for acks in ([{}], [{"ok": True}], [{"id": "c1"}], ["x"], [{"id": 1, "ok": True}]):
        status, body, _ = await dev.state({}, body={"time": 1, "values": {}, "acks": acks})
        assert (status, body["error"]) == (400, "invalid_payload")


async def test_commands_long_poll_returns_queued_command(setup):
    _, dev, rt = setup
    await dev.hello()
    task = asyncio.create_task(dev.commands(wait=5))
    await asyncio.sleep(0.1)
    rt.queue_command("brightness", 40)
    status, body, _ = await task
    assert status == 200 and body["commands"][0]["capability"] == "brightness"
    assert body["commands"][0]["value"] == 40


async def test_commands_wait_clamped(setup):
    _, dev, _ = setup
    await dev.hello()
    with patch.object(views, "MAX_WAIT_S", 0.05):
        for w in ("-5", "9999", "abc", "nan", "inf", ""):
            status, body, _ = await asyncio.wait_for(dev.commands(wait=w), 2)
            assert status == 200 and body["commands"] == []


async def test_responses_are_compact_fixed_order(setup):
    client, dev, rt = setup
    _, h, raw = await dev.hello()
    assert raw == json.dumps(h, separators=(",", ":"))
    assert list(h) == ["contract", "heartbeat_s", "poll_wait_s", "config"]
    assert list(h["config"]) == ["config_rev", "enabled", "interval_s"]
    _, s, raw = await dev.state({"battery_level": 1})
    assert raw == json.dumps(s, separators=(",", ":")) and list(s) == ["config_rev"]
    rt.queue_command("brightness", 40)
    _, c, raw = await dev.commands()
    assert raw == json.dumps(c, separators=(",", ":"))
    assert list(c) == ["config_rev", "commands"]
    assert list(c["commands"][0]) == ["id", "capability", "value", "issued_at"]
    _, cf, raw = await dev.config()
    assert raw == json.dumps(cf, separators=(",", ":"))
    assert list(cf) == ["config_rev", "enabled", "interval_s"]


async def test_concurrent_polls_newer_wins(setup):
    _, dev, rt = setup
    await dev.hello()
    t1 = asyncio.create_task(dev.commands(wait=5))
    await asyncio.sleep(0.1)
    t2 = asyncio.create_task(dev.commands(wait=5))
    await asyncio.sleep(0.1)
    rt.queue_command("brightness", 10)
    assert (await t1)[1]["commands"] == []
    assert (await t2)[1]["commands"][0]["value"] == 10


async def test_config_endpoint(setup):
    _, dev, _ = setup
    _, h, _ = await dev.hello()
    status, cf, _ = await dev.config()
    assert status == 200 and cf == h["config"]


async def test_error_precedence(setup):
    client, dev, _ = setup
    assert (await FakeDevice(client, "/api/panel_control/nope", "bad").hello())[0] == 404
    bad = FakeDevice(client, BASE, "bad")
    assert (await bad.hello())[0] == 401
    assert (await dev.hello({"contract": 2}))[1]["error"] == "unsupported_contract"
    await dev.hello()
    # state before hello on a restored runtime, with an invalid body too
    rt = setup[2]
    rt.restore(list(rt.declared.values()))
    status, body, _ = await dev.state({}, body={"junk": 1})
    assert (status, body["error"]) == (409, "hello_required")
    for _ in range(10):
        await bad.hello()
    assert (await dev.hello())[0] == 429  # locked IP, valid token


async def test_command_value_formatting(setup):
    _, dev, rt = setup
    await dev.hello()
    rt.queue_command("brightness", 0.00001)
    _, _, raw = await dev.commands()
    assert '"value":0,' in raw
    rt.queue_command("brightness", 12.345)
    _, _, raw = await dev.commands()
    assert "e" not in raw.split('"value":')[1].split(",")[0].lower()


async def test_x_forwarded_for_ignored(setup):
    from types import SimpleNamespace

    from custom_components.panel_control.lockout import Lockout

    hass = setup[0].server.app["hass"]
    req = SimpleNamespace(app={"hass": hass}, remote="1.2.3.4",
                          headers={"Authorization": "Bearer wrong", "X-Forwarded-For": "9.9.9.9"})
    with patch.object(Lockout, "record_failure") as spy:
        resp = views.HelloView()._auth(req, "kindle_test")
    assert resp.status == 401
    spy.assert_called_once_with("1.2.3.4")


HUGE = 10**400


async def test_huge_ints_rejected_cleanly(setup):
    _, dev, _ = setup
    for k in ("min", "max"):
        h = {"contract": 1, "agent_version": "1", "capabilities": [{"id": "brightness", k: HUGE}],
             "device": {"name": "a", "manufacturer": "b", "model": "c", "sw_version": "d"}}
        assert (await dev.hello(h))[0] == 400
    await dev.hello()
    assert (await dev.state({"brightness": HUGE}))[0] == 400
    assert (await dev.state({"brightness": 5}))[0] == 200


@pytest.mark.parametrize("t,status", [(-1, 400), (4102444801, 400), (HUGE, 400),
                                      (0, 200), (4102444800, 200)])
async def test_state_time_bounds(setup, t, status):
    _, dev, _ = setup
    await dev.hello()
    assert (await dev.state({}, time=t))[0] == status
