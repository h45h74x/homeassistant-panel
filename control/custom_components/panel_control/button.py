from homeassistant.components.button import ButtonEntity

from .entity import PanelEntity, setup_kind


async def async_setup_entry(hass, entry, async_add_entities):
    setup_kind(hass, entry, async_add_entities, "button", PanelButton)


class PanelButton(PanelEntity, ButtonEntity):
    async def async_press(self) -> None:
        self._queue(None)
