import asyncio
import json
from unittest.mock import patch

import pytest
from pytest_homeassistant_custom_component.common import MockConfigEntry

from homeassistant.setup import async_setup_component

from custom_components.panel_control import views
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
    assert await async_setup_component(hass, DOMAIN, {})
    await hass.async_block_till_done()
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
    loop = asyncio.get_running_loop()
    with patch.object(views, "MAX_WAIT_S", 0.4):
        for w, held in (("-5", False), ("0", False), ("abc", False), ("nan", False), ("", False),
                        ("9999", True), ("inf", True)):
            t0 = loop.time()
            status, body, _ = await asyncio.wait_for(dev.commands(wait=w), 3)
            dt = loop.time() - t0
            assert status == 200 and body["commands"] == []
            assert (0.35 <= dt < 1.5) if held else dt < 0.3, (w, dt)


async def test_surrogate_token_is_401_and_counts(hass, setup):
    # HA's own auth middleware chokes on a raw 0xFF Bearer byte before any view runs (jwt decode),
    # so the view is exercised directly with the str aiohttp would hand it (surrogateescape).
    from types import SimpleNamespace
    req = SimpleNamespace(app={"hass": hass}, remote="1.2.3.4",
                          headers={"Authorization": "Bearer \udcff"})
    for _ in range(10):
        r = views.HelloView()._auth(req, "kindle_test")
        assert r.status == 401
    assert views.HelloView()._auth(req, "kindle_test").status == 429


async def _hello_with(dev, mutate):
    h = json.loads((CONTRACT / "fixtures" / "valid" / "hello-ey21.json").read_text())
    mutate(h)
    return (await dev.hello(h))[0]


async def test_hello_rejects_min_gt_max_and_long_strings(setup):
    _, dev, _ = setup
    assert await _hello_with(dev, lambda h: h["capabilities"].__setitem__(
        0, {"id": "brightness", "min": 50, "max": 10})) == 400
    for key in ("name", "manufacturer", "model", "sw_version", "hw_version", "mac"):
        assert await _hello_with(dev, lambda h, k=key: h["device"].__setitem__(k, "x" * 201)) == 400
    assert await _hello_with(dev, lambda h: h.__setitem__("agent_version", "x" * 201)) == 400
    assert await _hello_with(dev, lambda h: h["device"].__setitem__("name", "x" * 200)) == 200
