import json
from pathlib import Path

CAPS = json.loads((Path(__file__).parent.parent / "catalog.json").read_text())["capabilities"]
BY_ID = {c["id"]: c for c in CAPS}

IDS = [
    "brightness", "warmth", "keep_awake", "refresh_screen", "sleep", "battery_level", "charging",
    "frontlight_on", "power_state", "cpu_usage", "cpu_load", "memory_total", "memory_free",
    "storage_total", "storage_free", "rootfs_used_percent", "clock_offset", "uptime",
    "battery_temperature", "battery_voltage", "battery_current", "wifi_signal",
    "ip_address", "ssid", "mac_address", "kernel_version",
]


def test_ids_match_spec():
    assert [c["id"] for c in CAPS] == IDS
    assert "lock" not in BY_ID


def test_ids_unique():
    assert len(BY_ID) == len(CAPS)


def test_report_interval_consistency():
    for c in CAPS:
        assert isinstance(c["interval_s"], int) == (c["report"] == "interval"), c["id"]


def test_sensitive_only_network_identity():
    assert {c["id"] for c in CAPS if c["sensitive"]} == {"ip_address", "ssid", "mac_address"}


def test_brightness_range():
    for i in ("brightness", "warmth"):
        c = BY_ID[i]
        assert (c["type"], c["unit"], c["min"], c["max"], c["access"]) == ("number", "%", 0, 100, "rw")


def test_power_state_enum():
    assert BY_ID["power_state"]["values"] == ["active", "screensaver", "suspended"]


def test_refresh_screen_is_value_less_button():
    c = BY_ID["refresh_screen"]
    assert (c["entity"], c["access"], c["type"]) == ("button", "w", "none")


def test_sleep_is_value_less_button():
    c = BY_ID["sleep"]
    assert (c["category"], c["sensitive"], c["entity"], c["access"], c["type"], c["report"]) == (
        "control", False, "button", "w", "none", "none")
    assert (c["unit"], c["min"], c["max"], c["values"], c["interval_s"]) == (None,) * 5
