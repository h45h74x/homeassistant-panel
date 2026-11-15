"""The only place HA device classes and units live. Keys are catalog capability ids."""
from homeassistant.components.binary_sensor import BinarySensorDeviceClass as B
from homeassistant.components.sensor import SensorDeviceClass as S
from homeassistant.const import (PERCENTAGE, UnitOfElectricCurrent, UnitOfElectricPotential,
                                 UnitOfInformation, UnitOfTemperature, UnitOfTime)

_SIZE = {"device_class": S.DATA_SIZE, "unit": UnitOfInformation.BYTES,
         "display_unit": UnitOfInformation.MEGABYTES}
_DURATION = {"device_class": S.DURATION, "unit": UnitOfTime.SECONDS}

BINARY_SENSOR = {"charging": B.BATTERY_CHARGING}

# numeric sensors; anything not listed is a plain number or text sensor without class/unit
SENSOR = {
    "battery_level": {"device_class": S.BATTERY, "unit": PERCENTAGE},
    "battery_temperature": {"device_class": S.TEMPERATURE, "unit": UnitOfTemperature.CELSIUS},
    "battery_voltage": {"device_class": S.VOLTAGE, "unit": UnitOfElectricPotential.VOLT},
    "battery_current": {"device_class": S.CURRENT, "unit": UnitOfElectricCurrent.MILLIAMPERE},
    "memory_total": _SIZE, "memory_free": _SIZE, "storage_total": _SIZE, "storage_free": _SIZE,
    "uptime": _DURATION, "clock_offset": _DURATION,
    "wifi_signal": {"unit": PERCENTAGE},
    "cpu_usage": {"unit": PERCENTAGE},
    "rootfs_used_percent": {"unit": PERCENTAGE},
}

NUMBER_UNIT = {"brightness": PERCENTAGE, "warmth": PERCENTAGE}
