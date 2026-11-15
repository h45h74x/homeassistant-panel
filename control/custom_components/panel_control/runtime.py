"""Per-device runtime state: declared capabilities, command queue, availability.

No Home Assistant imports. The enabled set lives in `self.enabled`: it is seeded
from `enabled_default` on `apply_hello`/`restore` and overwritten by the set the
caller passes to `config()` / `apply_state()`; `queue_command` checks it.
"""
from __future__ import annotations

import asyncio
import json
import time
import zlib
from pathlib import Path
from typing import Any, Callable

CATALOG = {
    c["id"]: c
    for c in json.loads((Path(__file__).parent / "catalog.json").read_text())["capabilities"]
}
COMMAND_TTL = 300


class DeviceRuntime:
    def __init__(self, device_id: str, enabled_default: Callable[[str], bool],
                 now: Callable[[], float] = time.time) -> None:
        self.device_id = device_id
        self._default = enabled_default
        self._now = now
        self.declared: dict[str, dict] = {}
        self.enabled: set[str] = set()
        self.needs_hello = False
        self.last_contact: float | None = None
        self.last_acks: list[dict] = []
        self._queue: dict[str, dict] = {}
        self._counter = 0
        self._waiter: asyncio.Future | None = None

    def _declare(self, caps: list[dict]) -> None:
        for c in caps:
            if c["id"] not in CATALOG:
                raise ValueError(f"unknown capability {c['id']}")
        self.declared = {c["id"]: c for c in caps}
        self.enabled = {i for i in self.declared if self._default(i)}
        self._queue = {k: v for k, v in self._queue.items() if k in self.declared}

    def restore(self, declared: list[dict]) -> None:
        self._declare(declared)
        self.needs_hello = True

    def apply_hello(self, hello: dict) -> None:
        self._declare(hello.get("capabilities", []))
        self.needs_hello = False
        self.touch()

    def touch(self) -> None:
        self.last_contact = self._now()

    def available(self, heartbeat_s: int = 60) -> bool:
        return self.last_contact is not None and self._now() - self.last_contact <= 3 * heartbeat_s

    def clock_offset(self, device_time: int) -> int:
        return int(round(device_time - self._now()))

    def config(self, enabled: set[str]) -> dict:
        self.enabled = set(enabled)
        ids = sorted(i for i in enabled if i in self.declared)
        intervals = {}
        for i in ids:
            report = CATALOG[i]["report"]
            if report == "interval":
                intervals[i] = CATALOG[i]["interval_s"]
            elif report == "hello":
                intervals[i] = 86400
        body = json.dumps({"enabled": ids, "interval_s": intervals},
                          sort_keys=True, separators=(",", ":"))
        return {"config_rev": zlib.crc32(body.encode()), "enabled": ids, "interval_s": intervals}

    def apply_state(self, state: dict, enabled: set[str]) -> dict[str, Any]:
        self.enabled = set(enabled)
        self.touch()
        self.last_acks = list(state.get("acks", []))
        acked = {a["id"] for a in self.last_acks}
        self._queue = {k: v for k, v in self._queue.items() if v["id"] not in acked}
        ok = lambda i: i in self.declared and i in enabled  # noqa: E731
        out = {i: v for i, v in state.get("values", {}).items()
               if ok(i) and i != "clock_offset" and CATALOG[i]["access"] != "w"}
        if ok("clock_offset") and "time" in state:
            out["clock_offset"] = self.clock_offset(state["time"])
        return out

    def queue_command(self, capability: str, value) -> str:
        cat = CATALOG.get(capability)
        if cat is None or capability not in self.declared:
            raise ValueError(f"undeclared capability {capability}")
        if capability not in self.enabled:
            raise ValueError(f"disabled capability {capability}")
        if cat["access"] == "r":
            raise ValueError(f"read-only capability {capability}")
        t = cat["type"]
        if t == "none":
            value = None
        elif t == "boolean":
            if not isinstance(value, bool):
                raise ValueError("boolean expected")
        elif t == "number":
            if isinstance(value, bool) or not isinstance(value, (int, float)) or value != value:
                raise ValueError("number expected")
            decl = self.declared[capability]
            lo = max(x for x in (cat["min"], decl.get("min")) if x is not None) if (
                cat["min"] is not None or decl.get("min") is not None) else None
            hi = min(x for x in (cat["max"], decl.get("max")) if x is not None) if (
                cat["max"] is not None or decl.get("max") is not None) else None
            if (lo is not None and value < lo) or (hi is not None and value > hi):
                raise ValueError(f"{capability} out of range")
            value = round(value, 2)
            if value == int(value):
                value = int(value)
        else:
            raise ValueError(f"{capability} not commandable")
        self._counter += 1
        cid = f"c{self._counter:x}"
        self._queue[capability] = {"id": cid, "capability": capability, "value": value,
                                   "issued_at": int(self._now())}
        if self._waiter and not self._waiter.done():
            self._waiter.set_result(None)
        return cid

    def take_commands(self) -> list[dict]:
        now = self._now()
        cmds = [c for c in self._queue.values() if now - c["issued_at"] <= COMMAND_TTL]
        self._queue = {}
        return cmds

    async def wait_commands(self, wait: float) -> list[dict]:
        if self._queue:
            return self.take_commands()
        if self._waiter and not self._waiter.done():
            self._waiter.set_result("superseded")
        fut = self._waiter = asyncio.get_running_loop().create_future()
        try:
            await asyncio.wait_for(asyncio.shield(fut), wait)
        except asyncio.TimeoutError:
            return []
        finally:
            if self._waiter is fut:
                self._waiter = None
        return [] if fut.result() == "superseded" else self.take_commands()
