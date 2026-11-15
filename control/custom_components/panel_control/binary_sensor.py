from homeassistant.components.binary_sensor import BinarySensorEntity

from .entity import PanelEntity, setup_kind
from .mapping import BINARY_SENSOR


async def async_setup_entry(hass, entry, async_add_entities):
    setup_kind(hass, entry, async_add_entities, "binary_sensor", PanelBinarySensor)


class PanelBinarySensor(PanelEntity, BinarySensorEntity):
    def __init__(self, entry, rt, cap):
        super().__init__(entry, rt, cap)
        self._attr_device_class = BINARY_SENSOR.get(cap)

    @property
    def is_on(self):
        return self._value
