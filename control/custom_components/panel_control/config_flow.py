"""Config flow: ask for a name, then show the URL and passphrase to copy into the Kindle config."""
import ipaddress
from urllib.parse import urlparse

import voluptuous as vol

from homeassistant.components.network import async_get_source_ip
from homeassistant.config_entries import ConfigFlow, OptionsFlow
from homeassistant.core import HomeAssistant
from homeassistant.util import slugify

from . import passphrase
from .const import DOMAIN

DEFAULT_PORT = 8123
NOTE = "The Kindle cannot resolve .local names, use an IP."


async def _base_url(hass: HomeAssistant) -> tuple[str, str]:
    """Return (base url, note). The Kindle only resolves IPs, so a hostname gets a note."""
    if hass.config.internal_url:
        url = hass.config.internal_url.rstrip("/")
        try:
            ipaddress.ip_address(urlparse(url).hostname or "")
            return url, ""
        except ValueError:
            return url, NOTE
    ip = await async_get_source_ip(hass)
    host = f"[{ip}]" if ":" in ip else ip
    # hass.config.api.port is set by the http component (a dependency); HTTPServer has no port attribute
    port = getattr(hass.config.api, "port", None) or DEFAULT_PORT
    return f"http://{host}:{port}", ""


class PanelControlConfigFlow(ConfigFlow, domain=DOMAIN):
    VERSION = 1

    def __init__(self):
        self._name = ""
        self._device_id = ""
        self._passphrase = ""

    async def async_step_user(self, user_input=None):
        errors = {}
        if user_input is not None:
            name = user_input["name"].strip()
            if not name:
                errors["name"] = "name_required"
            else:
                base = slugify(name)  # empty slug becomes "unknown"
                taken = {e.unique_id for e in self._async_current_entries(include_ignore=True)}
                device_id, n = base, 1
                while device_id in taken:
                    n += 1
                    device_id = f"{base}_{n}"
                await self.async_set_unique_id(device_id)
                self._abort_if_unique_id_configured()
                self._name, self._device_id = name, device_id
                self._passphrase = passphrase.generate()
                return await self.async_step_pairing()
        return self.async_show_form(step_id="user", data_schema=vol.Schema({vol.Required("name"): str}),
                                    errors=errors)

    async def async_step_pairing(self, user_input=None):
        if user_input is not None:
            return self.async_create_entry(title=self._name, data={
                "device_id": self._device_id, "passphrase": self._passphrase, "name": self._name})
        base, note = await _base_url(self.hass)
        return self.async_show_form(step_id="pairing", description_placeholders={
            "url": f"{base}/api/{DOMAIN}/{self._device_id}", "passphrase": self._passphrase,
            "url_note": note})

    @staticmethod
    def async_get_options_flow(config_entry):
        return PanelControlOptionsFlow()


class PanelControlOptionsFlow(OptionsFlow):
    async def async_step_init(self, user_input=None):
        if user_input is not None:
            self._new = passphrase.generate()
            self.hass.config_entries.async_update_entry(
                self.config_entry, data={**self.config_entry.data, "passphrase": self._new})
            return await self.async_step_done()
        return self.async_show_form(step_id="init")

    async def async_step_done(self, user_input=None):
        if user_input is not None:
            return self.async_create_entry(data=self.config_entry.options)
        return self.async_show_form(step_id="done", description_placeholders={"passphrase": self._new})
