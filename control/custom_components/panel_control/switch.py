from homeassistant.components.switch import SwitchEntity

from .entity import PanelEntity, setup_kind


async def async_setup_entry(hass, entry, async_add_entities):
    setup_kind(hass, entry, async_add_entities, "switch", PanelSwitch)


class PanelSwitch(PanelEntity, SwitchEntity):
    @property
    def is_on(self):
        return self._value

    async def async_turn_on(self, **kwargs) -> None:
        self._queue(True)

    async def async_turn_off(self, **kwargs) -> None:
        self._queue(False)
