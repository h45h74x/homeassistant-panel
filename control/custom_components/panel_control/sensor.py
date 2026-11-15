from homeassistant.components.sensor import SensorDeviceClass, SensorEntity, SensorStateClass

from .entity import PanelEntity, setup_kind
from .mapping import SENSOR
from .runtime import CATALOG


async def async_setup_entry(hass, entry, async_add_entities):
    setup_kind(hass, entry, async_add_entities, "sensor", PanelSensor)


class PanelSensor(PanelEntity, SensorEntity):
    def __init__(self, entry, rt, cap):
        super().__init__(entry, rt, cap)
        c, m = CATALOG[cap], SENSOR.get(cap, {})
        if c["type"] == "enum":
            self._attr_device_class = SensorDeviceClass.ENUM
            self._attr_options = c["values"]
        else:
            self._attr_device_class = m.get("device_class")
            self._attr_native_unit_of_measurement = m.get("unit")
            if "display_unit" in m:
                self._attr_suggested_unit_of_measurement = m["display_unit"]
            if c["type"] == "number":
                self._attr_state_class = SensorStateClass.MEASUREMENT

    @property
    def native_value(self):
        if CATALOG[self._cap]["type"] == "enum" and self._value not in self._attr_options:
            return None
        return self._value
