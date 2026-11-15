# Control, after v1

Each item needs a catalog entry in the contract first (id, category, unit), then a device implementation. Order below is a suggestion, not a plan.

## 1. `lock` (dropped from v1 on 2026-11-15)
Update (v1.1): the one-way `sleep` button (value-less press, no state, no wake) now exists in the catalog. A `lock`/`unlock` switch with state and wake remains future work.

Why dropped: after the system lock (`powerd powerButton 1`) the EY21 suspends within about 30-60 s and drops Wi-Fi. `wakeUp 1` unlocks over the network only inside that window, so a `lock` switch would strand the device. Full evidence: `devices/kindle-ey21/README.md` ("Lock findings").

To bring it back, one of these must be proven first (each is a small probe, one at a time, with a recovery route per `docs/probing-devices.md`):
- **RTC wake:** `rtcWakeup <s>` failed with `lipcPropErrInvalidState` in `active` and `screenSaver`. Try in `readyToSuspend`, or arm `/sys/class/rtc/*/wakealarm`. The agent would arm a wake before locking and poll briefly on each wake.
- **Fake lock:** agent stays awake, brightness 0 plus blank screen. Reachable, but more battery and not a real lock.
- **Custom screensaver:** no mechanism installed (no `linkss`). Shared prerequisite with Dashboard TODO #2.
- **Touch blocking:** only if a power measurement shows a real saving.
- Power measurement needs a quiet device without an SSH session (log to a file on the device, read after waking).

If it returns, the catalog entry was: `lock`, control, HA `lock` entity, `locked`/`unlocked`, plus a declared `unlock` reliability (`reliable`, `best_effort`, `none`) and assumed state when the device cannot report.

## 2. Deferred capabilities
- More Wi-Fi diagnostics: `wifi_bssid`, `wifi_channel`, `wifi_security`, `wifi_country`, gateway, DNS. All in the EY21's `lipc-get-prop com.lab126.wifid 711` text block.
- `battery_capacity_mah`: sysfs `yoshi_battery0/battery_mAH` (reads 646); unclear if remaining or design capacity.
- `process_count`: `/proc/loadavg` (3/345 seen).
- `last_contact_latency`: time the agent needs to answer a command; helps tune poll intervals.
- `auto_brightness`: `powerd flAuto` (reads 0), switch; write untested.
- `reboot` and `restart_ui` buttons: risky. Disabled by default and behind a confirmation. Untested.
- Skipped on purpose: reading and book data. `agent_version` belongs in `hello`, not an entity.
- Show a message on screen and screenshot (`/dev/fb0`): Dashboard-product features, see [dashboard.md](dashboard.md).

## 3. Autostart on boot
The EY21 agent only starts from KUAL and stops on reboot. A wall panel wants it to survive power loss: an upstart job or a KUAL auto-run entry. Needs a probe of what the EY21 firmware allows without touching the system partition.

## 4. More devices
Only the EY21 is supported. A second device (the user also develops on a Paperwhite 12th gen, see `README.md`) means a new `devices/<id>/` README via `docs/probing-devices.md` and a new device layer behind the same contract. It must not change the contract or the integration; if it does, the contract was wrong, fix it there. Warmth is the first capability another device would declare.

## 5. Pairing and security
- If the 47-bit passphrase plus lockout proves too weak or too fiddly: per-device short pairing code shown in HA and exchanged once for a long token.
- https: the base URL is configurable, so a reverse proxy works already; document it, test it.
- Typed config on the device: a search-bar command is impossible on the EY21 (the `;log` dispatch passes no arguments, see the device README). Other routes if USB editing proves annoying: a KOReader plugin (KOReader is installed) or patching the dispatch (system partition, not allowed). A native Jobman-style Slint UI was rejected as YAGNI (Jobman is PW4+ only).
