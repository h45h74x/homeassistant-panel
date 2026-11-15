from homeassistant.components.number import NumberEntity

from .entity import PanelEntity, setup_kind
from .mapping import NUMBER_UNIT
from .runtime import CATALOG


async def async_setup_entry(hass, entry, async_add_entities):
    setup_kind(hass, entry, async_add_entities, "number", PanelNumber)


class PanelNumber(PanelEntity, NumberEntity):
    _attr_native_step = 1

    def __init__(self, entry, rt, cap):
        super().__init__(entry, rt, cap)
        self._attr_native_unit_of_measurement = NUMBER_UNIT.get(cap)

    @property
    def native_min_value(self):
        return self._bound("min", max)

    @property
    def native_max_value(self):
        return self._bound("max", min)

    def _bound(self, key, pick):
        vals = [x for x in (CATALOG[self._cap][key], self._rt.declared.get(self._cap, {}).get(key))
                if x is not None]
        return pick(vals)

    @property
    def native_value(self):
        return self._value

    async def async_set_native_value(self, value: float) -> None:
        self._queue(value)  # no optimistic state: the device's next state post shows the value
