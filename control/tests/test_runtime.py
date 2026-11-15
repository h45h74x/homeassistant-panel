import asyncio
import json
import re
import zlib

import pytest

from custom_components.panel_control.runtime import DeviceRuntime


class Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


def hello(*ids, **limits):
    caps = []
    for i in ids:
        c = {"id": i}
        c.update(limits.get(i, {}))
        caps.append(c)
    return {"contract": 1, "capabilities": caps}


ALL = ("brightness", "keep_awake", "refresh_screen", "battery_level",
       "memory_total", "kernel_version", "frontlight_on", "clock_offset")


def make(ids=ALL, enabled=None):
    clock = Clock()
    rt = DeviceRuntime("d1", lambda i: True, clock)
    rt.apply_hello(hello(*ids))
    if enabled is not None:
        rt.enabled = set(enabled)
    return rt, clock


def test_hello_replaces_declared():
    rt, _ = make(("brightness", "keep_awake"))
    rt.apply_hello(hello("brightness"))
    with pytest.raises(ValueError):
        rt.queue_command("keep_awake", True)
    with pytest.raises(ValueError):
        rt.apply_hello(hello("lock"))


def test_restore_requires_hello():
    rt = DeviceRuntime("d1", lambda i: True, Clock())
    rt.restore([{"id": "brightness"}])
    assert rt.needs_hello is True
    rt.apply_hello(hello("brightness"))
    assert rt.needs_hello is False


def test_state_drops_disabled_and_undeclared():
    rt, _ = make(enabled={"battery_level", "refresh_screen", "clock_offset"})
    en = rt.enabled
    got = rt.apply_state({"time": 1010, "values": {
        "battery_level": 80, "memory_total": 5, "cpu_usage": 1,
        "refresh_screen": 1, "clock_offset": 99}}, en)
    assert got == {"battery_level": 80, "clock_offset": 10}
    got = rt.apply_state({"time": 1000, "values": {"battery_level": None}}, {"battery_level"})
    assert got == {"battery_level": None}


def test_acks_recorded():
    rt, _ = make()
    acks = [{"id": "c1", "ok": False, "error": "x"}]
    rt.apply_state({"time": 1000, "values": {}, "acks": acks}, rt.enabled)
    assert rt.last_acks == acks
    assert rt.available()


def test_queue_latest_value_wins():
    rt, _ = make()
    a = rt.queue_command("brightness", 10)
    b = rt.queue_command("brightness", 20)
    assert a != b and re.fullmatch(r"[a-z0-9]{1,16}", b)
    cmds = rt.take_commands()
    assert cmds == [{"id": b, "capability": "brightness", "value": 20, "issued_at": 1000}]
    assert list(cmds[0]) == ["id", "capability", "value", "issued_at"]
    assert rt.take_commands() == []


def test_command_expires_after_300s():
    rt, clock = make()
    rt.queue_command("brightness", 10)
    clock.t += 301
    assert rt.take_commands() == []


def test_refuses_undeclared_disabled_readonly():
    rt, _ = make(enabled={"brightness", "battery_level"})
    for cap in ("warmth", "keep_awake", "battery_level", "nope"):
        with pytest.raises(ValueError):
            rt.queue_command(cap, 1)


def test_number_out_of_range_rejected():
    rt, _ = make()
    with pytest.raises(ValueError):
        rt.queue_command("brightness", 101)
    with pytest.raises(ValueError):
        rt.queue_command("brightness", -1)
    rt.apply_hello(hello("brightness", brightness={"max": 50}))
    with pytest.raises(ValueError):
        rt.queue_command("brightness", 51)


def test_number_formatting():
    rt, _ = make()
    rt.queue_command("brightness", 50.0)
    assert rt.take_commands()[0]["value"] == 50
    rt.queue_command("brightness", 12.3456)
    v = rt.take_commands()[0]["value"]
    assert v == 12.35
    rt.queue_command("brightness", 1e-9)
    assert rt.take_commands()[0]["value"] == 0


def test_press_collapses_duplicates():
    rt, _ = make()
    rt.queue_command("refresh_screen", None)
    rt.queue_command("refresh_screen", None)
    cmds = rt.take_commands()
    assert len(cmds) == 1 and cmds[0]["value"] is None


def rev(enabled, intervals):
    s = json.dumps({"enabled": enabled, "interval_s": intervals},
                   sort_keys=True, separators=(",", ":"))
    return zlib.crc32(s.encode())


def test_config_rev_stable_and_changes():
    rt, _ = make()
    a = rt.config({"brightness", "battery_level"})
    assert rt.config({"battery_level", "brightness"}) == a
    assert rt.config({"brightness"})["config_rev"] != a["config_rev"]
    assert list(a) == ["config_rev", "enabled", "interval_s"]
    assert a["config_rev"] == rev(["battery_level", "brightness"], {"battery_level": 60})


def test_config_intervals():
    rt, _ = make()
    c = rt.config(set(ALL) | {"warmth"})
    assert "warmth" not in c["enabled"]
    assert c["enabled"] == sorted(ALL)
    assert c["interval_s"] == {"battery_level": 60, "memory_total": 3600,
                               "clock_offset": 3600, "kernel_version": 86400}


def test_available_after_three_missed_heartbeats():
    rt, clock = make()
    rt2 = DeviceRuntime("d2", lambda i: True, clock)
    assert not rt2.available()
    rt2.touch()
    clock.t += 180
    assert rt2.available()
    clock.t += 1
    assert not rt2.available()


def test_clock_offset():
    rt, clock = make()
    clock.t = 5000.4
    assert rt.clock_offset(5030) == 30
    assert rt.clock_offset(4990) == -10


async def test_wait_commands_wakes_on_queue():
    rt, _ = make()
    t = asyncio.create_task(rt.wait_commands(5))
    await asyncio.sleep(0.01)
    assert not t.done()
    rt.queue_command("brightness", 5)
    assert (await t)[0]["value"] == 5
    rt.queue_command("brightness", 6)
    assert (await rt.wait_commands(5))[0]["value"] == 6


async def test_wait_commands_timeout():
    rt, _ = make()
    assert await rt.wait_commands(0.02) == []


async def test_second_waiter_supersedes_first():
    rt, _ = make()
    t1 = asyncio.create_task(rt.wait_commands(5))
    await asyncio.sleep(0.01)
    t2 = asyncio.create_task(rt.wait_commands(5))
    assert await t1 == []
    assert not t2.done()
    rt.queue_command("brightness", 7)
    assert (await t2)[0]["value"] == 7
