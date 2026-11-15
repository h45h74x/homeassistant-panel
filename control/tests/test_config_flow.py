import ipaddress
from urllib.parse import urlparse

from unittest.mock import patch

import pytest
from pytest_homeassistant_custom_component.common import MockConfigEntry

from homeassistant import config_entries
from homeassistant.data_entry_flow import FlowResultType

from custom_components.panel_control import passphrase
from custom_components.panel_control.const import DOMAIN

from fake_device import FakeDevice


@pytest.fixture(autouse=True)
def _enable(enable_custom_integrations):
    pass


async def _start(hass, name="Kitchen Kindle"):
    r = await hass.config_entries.flow.async_init(DOMAIN, context={"source": config_entries.SOURCE_USER})
    assert r["type"] == FlowResultType.FORM and r["step_id"] == "user"
    return await hass.config_entries.flow.async_configure(r["flow_id"], {"name": name})


async def _create(hass, name="Kitchen Kindle"):
    r = await _start(hass, name)
    return await hass.config_entries.flow.async_configure(r["flow_id"], {})


async def test_user_step_creates_entry(hass):
    r = await _create(hass)
    assert r["type"] == FlowResultType.CREATE_ENTRY and r["title"] == "Kitchen Kindle"
    d = r["data"]
    assert d["device_id"] == "kitchen_kindle" and d["name"] == "Kitchen Kindle"
    words = d["passphrase"].split("-")
    assert len(words) == 5 and all(w in passphrase._WORDS for w in words)


async def test_second_device_same_name_gets_distinct_id(hass):
    await _create(hass)
    assert (await _create(hass))["data"]["device_id"] == "kitchen_kindle_2"
    assert (await _create(hass))["data"]["device_id"] == "kitchen_kindle_3"


async def test_empty_slug_falls_back(hass):
    assert (await _create(hass, "!!!"))["data"]["device_id"] == "unknown"


@pytest.mark.parametrize("name", ["", "   "])
async def test_blank_name_rejected(hass, name):
    r = await _start(hass, name)
    assert r["type"] == FlowResultType.FORM and r["step_id"] == "user" and r["errors"]["name"]
    assert not hass.config_entries.async_entries(DOMAIN)


async def test_pairing_info_shown(hass):
    hass.config.internal_url = "http://192.168.1.5:8123"
    r = await _start(hass)
    assert r["type"] == FlowResultType.FORM and r["step_id"] == "pairing" and r["data_schema"] is None
    ph = r["description_placeholders"]
    assert ph["url"] == "http://192.168.1.5:8123/api/panel_control/kitchen_kindle"
    assert len(ph["passphrase"].split("-")) == 5 and ph["url_note"] == ""
    # the entry only exists after the pairing form is submitted
    assert not hass.config_entries.async_entries(DOMAIN)
    done = await hass.config_entries.flow.async_configure(r["flow_id"], {})
    assert done["data"]["passphrase"] == ph["passphrase"]


async def test_pairing_url_host_is_ip_when_no_internal_url(hass):
    hass.config.internal_url = None
    r = await _start(hass)
    url = r["description_placeholders"]["url"]
    assert url.endswith("/api/panel_control/kitchen_kindle")
    ipaddress.ip_address(urlparse(url).hostname)
    assert r["description_placeholders"]["url_note"] == ""


async def test_pairing_hostname_kept_with_note(hass):
    hass.config.internal_url = "http://homeassistant.local:8123"
    ph = (await _start(hass))["description_placeholders"]
    assert ph["url"] == "http://homeassistant.local:8123/api/panel_control/kitchen_kindle"
    assert ".local" in ph["url_note"] and "IP" in ph["url_note"]


async def _regenerate(hass, entry):
    r = await hass.config_entries.options.async_init(entry.entry_id)
    assert r["type"] == FlowResultType.FORM and r["step_id"] == "init"
    r = await hass.config_entries.options.async_configure(r["flow_id"], {})
    assert r["step_id"] == "done"
    new = r["description_placeholders"]["passphrase"]
    r = await hass.config_entries.options.async_configure(r["flow_id"], {})
    assert r["type"] == FlowResultType.CREATE_ENTRY
    await hass.async_block_till_done()
    return new


async def test_options_flow_regenerates_passphrase(hass):
    entry = (await _create(hass))["result"]
    old = entry.data["passphrase"]
    new = await _regenerate(hass, entry)
    assert new != old and entry.data["passphrase"] == new
    assert entry.data["device_id"] == "kitchen_kindle"


async def test_old_passphrase_401_new_works(hass, hass_client_no_auth):
    entry = (await _create(hass))["result"]
    old = entry.data["passphrase"]
    client = await hass_client_no_auth()
    base = "/api/panel_control/kitchen_kindle"
    assert (await FakeDevice(client, base, old).hello())[0] == 200
    new = await _regenerate(hass, entry)
    assert (await FakeDevice(client, base, old).hello())[0] == 401
    assert (await FakeDevice(client, base, new).hello())[0] == 200


@pytest.mark.parametrize("result", [None, "127.0.0.1", "::1", RuntimeError("boom")])
async def test_pairing_without_usable_ip_shows_placeholder(hass, result):
    hass.config.internal_url = None
    kw = {"side_effect": result} if isinstance(result, Exception) else {"return_value": result}
    with patch("custom_components.panel_control.config_flow.async_get_source_ip", **kw):
        r = await _start(hass)
    ph = r["description_placeholders"]
    assert r["step_id"] == "pairing" and "<HA-IP>" in ph["url"] and "LAN IP" in ph["url_note"]
