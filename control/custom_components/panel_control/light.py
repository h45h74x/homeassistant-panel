from homeassistant.components.light import ATTR_BRIGHTNESS, ColorMode, LightEntity
from homeassistant.core import callback

from .entity import PanelEntity, setup_kind


async def async_setup_entry(hass, entry, async_add_entities):
    setup_kind(hass, entry, async_add_entities, "light", PanelLight)


class PanelLight(PanelEntity, LightEntity):
    """Frontlight: capability `brightness` (percent 0-100) shown as a dimmable light."""
    _attr_color_mode = ColorMode.BRIGHTNESS
    _attr_supported_color_modes = {ColorMode.BRIGHTNESS}

    def __init__(self, entry, rt, cap):
        super().__init__(entry, rt, cap)
        self._last = 50  # restored by turn_on without brightness

    @property
    def is_on(self):
        return None if self._value is None else self._value > 0

    @property
    def brightness(self):
        return None if self._value is None else int(self._value * 255 / 100 + 0.5)

    @callback
    def _on_state(self, values):
        v = values.get(self._cap)
        if isinstance(v, (int, float)) and v > 0:
            self._last = v
        super()._on_state(values)

    async def async_turn_on(self, **kwargs) -> None:
        b = kwargs.get(ATTR_BRIGHTNESS)
        # no optimistic state: the device's next state post shows the value
        self._queue(self._last if b is None else max(1, int(b * 100 / 255 + 0.5)) if b > 0 else 0)

    async def async_turn_off(self, **kwargs) -> None:
        self._queue(0)
