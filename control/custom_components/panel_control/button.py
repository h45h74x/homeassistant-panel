from homeassistant.components.button import ButtonEntity

from .mapping import BUTTON_ICON
from .entity import PanelEntity, setup_kind


async def async_setup_entry(hass, entry, async_add_entities):
    setup_kind(hass, entry, async_add_entities, "button", PanelButton)


class PanelButton(PanelEntity, ButtonEntity):
    def __init__(self, entry, rt, cap) -> None:
        super().__init__(entry, rt, cap)
        self._attr_icon = BUTTON_ICON.get(cap)

    async def async_press(self) -> None:
        self._queue(None)
