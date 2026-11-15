# Kindle Paperwhite 1 (EY21): hardware facts and probe findings

Reference for anyone writing or improving the EY21 device layer. Everything here was observed on a real device over SSH (probe date 2026-11-15), unless marked *unverified*. The goal of this file is that nobody has to redo the research: read the findings, then jump to "Open experiments" for what is left.

Files in this folder:
- `probe-output.txt`: raw read-only probe (serial, board id, MAC and IP redacted).
- `step0-probe.sh` / `step0-output.txt`: tool availability and search-bar dispatch (read-only, 2026-11-15).
- `probe-rtc-wake.sh`: the last version (v3) of the on-device wake experiment. Run it only as described under "How to re-run".

## Supported features (EY21, against the contract's capability catalog)

Catalog, categories and meaning: `docs/superpowers/specs/2026-11-08-device-controls-design.md` ("Capability catalog"). This table is what the EY21 layer declares in `hello`. "Verified" means read or written on the real device; "to verify" means the source is standard or expected but has not been checked yet (the device was asleep when this table was written).

| Capability | Supported | Access | Device-specific implementation | Status / limits |
|---|---|---|---|---|
| `brightness` | yes | read/write | `lipc` `com.lab126.powerd flIntensity`, scale 0-24 mapped to 0-100 | verified; 0 not eye-verified as dark |
| `warmth` | **no** | none | hardware has no amber light (`currentAmberLevel` missing) | never declared |
| `keep_awake` | yes | read/write | `powerd preventScreenSaver` (0/1) | read verified (0), write **not tested**. Restore to 0 after tests; with 1 the device never locks or suspends |
| `refresh_screen` | yes | write | `eips -c` (used in the old `run.sh`) | **not tested** on this device; confirm `eips` exists and that it only flashes the panel |
| `sleep` | yes | write | `powerd preventScreenSaver 0`, then `powerButton 1` (same path as the physical power button); verified 2026-11-15: with `preventScreenSaver` 1 the lock never happens, hence the first write | verified command (2026-11-15): `active` to `screenSaver` within 3 s, Wi-Fi up for about 30-60 s, then suspend. One-way, state not readable, `wakeUp 1` from the network only works inside that window |
| `battery_level` | yes | read | `powerd battLevel` | verified |
| `charging` | yes | read | `powerd isCharging` | verified |
| `frontlight_on` | yes | read | `flIntensity` greater than 0 | derived from verified value |
| `power_state` | yes | read | `powerd state`: `active` to `active`, `screenSaver` and `readyToSuspend` to `screensaver`; suspended cannot be read (device unreachable) | verified |
| `cpu_usage` | yes | read | delta of the first line of `/proc/stat` between two polls | to verify |
| `cpu_load` | yes | read | first field of `/proc/loadavg` | verified |
| `memory_total` | yes | read | `/proc/meminfo` `MemTotal`, kB to bytes | verified (256180 kB) |
| `memory_free` | yes | read | `/proc/meminfo` MemFree+Buffers+Cached, kB to bytes | verified |
| `storage_total` | yes | read | `df -k /mnt/us`, kB to bytes | verified |
| `storage_free` | yes | read | `df -k /mnt/us`, kB to bytes | verified |
| `rootfs_used_percent` | yes | read | `df -k /` used percent (88% seen) | verified |
| `clock_offset` | yes | read | device `date +%s` sent by the agent, HA computes the difference | to verify |
| `uptime` | yes | read | first field of `/proc/uptime` | to verify |
| `battery_temperature` | yes, unit open | read | sysfs `yoshi_battery0/battery_temperature` (reads 73) or `powerd battTemperature` (also 73) | **unit unknown**: 73 at room temperature suggests Fahrenheit. Convert only after verifying (e.g. against a known temperature) |
| `battery_voltage` | yes | read | sysfs `yoshi_battery0/battery_voltage` (reads 4071, millivolts) to volts | read verified, unit by plausibility |
| `battery_current` | yes | read | sysfs `yoshi_battery0/battery_current` (reads -29, assumed mA, negative = discharging) | read verified, unit assumed |
| `wifi_signal` | yes | read | `lipc-get-prop com.lab126.wifid signalStrength` returns `5/5`, scale to percent | verified format |
| `ip_address` | yes | read | `ifconfig wlan0`, `inet addr:` | verified format (sensitive) |
| `ssid` | yes | read | `lipc-get-prop com.lab126.wifid` `711` text block (`2.3 AP: <ssid> (<bssid>)`) or `wpa_cli` | to verify (sensitive) |
| `mac_address` | yes | read | `/sys/class/net/wlan0/address` or `ifconfig wlan0` HWaddr | to verify (sensitive) |
| `kernel_version` | yes | read | `uname -r` | verified (`2.6.31-rt11-lab126`) |

Identity for `hello.device`: `name` from `hostname` (to verify), `manufacturer` = Amazon, `model` hardcoded by the EY21 layer as `Kindle Paperwhite 1 (EY21)` with a sanity check that `/proc/cpuinfo` reports `MX50 YOSHIME`, `hw_version` = board id (not sent by default), `sw_version` from the `System Software Version:` line in `/etc/version.txt` (verified), `serial_number` from `/proc/usid` (only if the user opts in; never log it).

Readable on the device but **not** in the catalog (so not exposed): auto-brightness flag (`flAuto`), powerd status text, firmware build date, the extra Wi-Fi details, `battery_mAH`. See `docs/future/control-v2.md` for the backlog. Adding any of these means extending the catalog first.

## 1. Device and environment

| Item | Value |
|---|---|
| Model | Kindle Paperwhite 1 (2012), board `Amazon.com MX50 YOSHIME`, "5th generation" |
| Firmware | `035-juno_6011_celeste_yoshime3`, built 2015-06-23, kernel 2.6.31-rt11-lab126, ARMv7 Cortex-A8 ~800 MHz |
| Memory | 256 MB RAM, only ~12 MB `MemFree` (~120 MB with buffers+cache) |
| Storage | root fs 88% full (~43 MB free): never write to `/`. User partition `/mnt/us` has ~1.2 GB free |
| Shell | BusyBox 1.17.1 as root. `curl`, `wget`, `nc`, `sqlite3`, `rtcwake`, `lipc-*` exist. No `grep -E`, no `nohup`, no `/sys/class/backlight`, no `/sys/class/power_supply` |
| Installed | USBNetwork (`/mnt/us/usbnet`), KUAL (`/mnt/us/extensions`), KOReader. SSH over the USB cable works (recovery route). Day-to-day SSH was over Wi-Fi |
| Wi-Fi | `wlan0`, driven by `wifid`/`cmd` over lipc |
| RTCs | `rtc0` (`mxc_rtc`, no `wakealarm`), `rtc1` (`pmic_rtc`, has `wakealarm`). `/sys/power/state` offers `standby mem` |

No warmth: `currentAmberLevel` does not exist, there is no amber frontlight. Do not declare a `warmth` capability.

### Tools on the device (probe 2026-11-15)
- **Missing:** `jq`, python, python3, perl, `od`, `base64`, `sha1sum`. Free RAM about 17 MB (128 MB with cache), `/` 88% full, `/mnt/us` 1.2 GB free.
- **Present:** `lua` 5.1.4 with `cjson` (`require "cjson"` works), BusyBox 1.17.1 (`awk`, `sed`, `tr`, `cut`, `timeout`, `flock`, `mktemp`, `hexdump`, `sha256sum`, `md5sum`, `rtcwake`, `crond`), `openssl`, `curl` 7.33.0 (OpenSSL 1.0.1g, zlib, c-ares), `wget`, `nc`, `sqlite3`.
- **Screen text:** `/usr/sbin/eips` (not on the PATH over SSH, call it by full path) and `fbink` (`/var/local/kmc/bin/fbink`, copied to `/mnt/us/libkh/bin/fbink`).
- **curl 7.33 long-poll (tested 2026-11-15 against a LAN server):** holds a 25 s and a 55 s response fine; exit codes `28` timeout, `7` refused, `52` reset, `6` DNS; HTTP errors return rc 0 unless `-f`. No mDNS: `.local` names do not resolve, use an IP.
- **JSON parsing:** `sed -n 's/.*"id":\([0-9]*\).*/\1/p'` works, and `lua` + `cjson` is available as a fallback.

### Search-bar commands (probe 2026-11-15)
- The jailbreak hotfix is installed (`/var/local/kmc/hotfix`, `Run Hotfix.run_hotfix` in `documents`). Its `install_dispatch.sh` replaces `/usr/bin/logThis.sh` with `/var/local/mkk/dispatch.sh`, so `;log <arg>` runs that script.
- The installed `logThis.sh` requires **exactly one** argument. `mrpi` (and anything starting with `m`) launches MRPI; `custom`/`runme` (anything starting with `r`) runs `/mnt/us/RUNME.sh` **without arguments**; anything else prints "Wrong arg". No `/app/kpp_app_cmds.json` exists on this firmware (old UI).
- Consequence: typed arguments never reach a script. A `;log pconnect <host> <passphrase>` command is impossible without patching `/usr/bin/logThis.sh` (immutable, system partition, not allowed). `;log runme` can only start a fixed `/mnt/us/RUNME.sh`.

## 2. Capability table (contract capability to lipc/sysfs)

| Capability | Read | Write | Native range | Notes |
|---|---|---|---|---|
| brightness | `lipc-get-prop com.lab126.powerd flIntensity` | `lipc-set-prop com.lab126.powerd flIntensity <n>` | 0 to 24 (`flMaxIntensity`) | Map to contract 0-100 with `round(n*100/24)`. Tested 3->4->3, 0, 24: rc=0 and exact readback, restored to 3. The frontlight is not in sysfs (`/sys/devices/platform/pmic_leds.*` are only R/G/B status LEDs). Clamp values in the agent (out-of-range untested). Not eye-verified that 0 is fully dark. `flAuto` (auto brightness) reads 0, `flTurboBrightnessIntensity` reads 0, both untouched |
| battery | `battLevel` (percent), `isCharging` (0/1), both on `com.lab126.powerd` | read-only | 0-100 | Extras seen: `battTemperature` (73, unit unknown), sysfs `/sys/devices/system/yoshi_battery/yoshi_battery0/battery_{capacity,current,voltage,temperature,mAH}` (capacity 88%, current -29 mA idle, voltage 4071, mAH 646). Current is signed, negative = discharging |
| system_version | `/etc/version.txt` | read-only | n/a | Parse the `System Software Version:` line |
| storage_free | `df -k /mnt/us` | read-only | n/a | |
| cpu_load | `/proc/loadavg` | read-only | n/a | |
| memory_free | `/proc/meminfo` | read-only | n/a | Use MemFree+Buffers+Cached, `MemFree` alone is misleadingly low |
| lock | `lipc-get-prop com.lab126.powerd state` | lock: `lipc-set-prop com.lab126.powerd powerButton 1`; unlock: `lipc-set-prop com.lab126.powerd wakeUp 1` | states below | One-way in v1, see section 4 and the design doc |

## 3. Power state machine (powerd)

`lipc-get-prop com.lab126.powerd state` returns `active`, `screenSaver`, `readyToSuspend`; once suspended nothing answers.

```
active --powerButton 1--> screenSaver (lock screen) --~60 s--> readyToSuspend --~10-45 s--> suspended
   ^                                                                 |                         |
   +----------------------- wakeUp 1 (needs Wi-Fi up) ---------------+-- RTC alarm / button ----+
```

Observed timings (seconds after `powerButton 1`):
- `screenSaver` reached in <3 s. `goingToScreenSaver` event fires immediately.
- `readyToSuspend` after ~60 s in most runs (30 s in the very first run: do not rely on it). Enters it several times: events `readyToSuspend 10, 8, 7, 7, 6, 2, 1` about 5 s apart, with a gap of ~20 s in the middle. The meaning of the number is unknown.
- Existing SSH sessions and TCP connections keep working through `screenSaver` and early `readyToSuspend`. Then the device suspends: Wi-Fi drops and SSH/ping die within ~70-75 s of locking.
- Ping (ICMP) fails already ~2 s after locking although SSH still works: never use ICMP as a liveness check for a locked device, use TCP or the agent's own heartbeat.
- What the user sees when locked: the normal Kindle lock screen (default Amazon images), backlight off, identical to a physical power-button press.

## 4. Lock and wake findings

### What works
- **Lock:** `powerButton 1` while `active`: rc=0, `screenSaver` in <3 s. This is the real system lock (lowest power). The stock screensaver is shown; a custom screensaver is not available because no screensaver hack is installed (`/mnt/us/linkss` and `/mnt/us/screensavers` do not exist).
- **Unlock over the network:** `wakeUp 1`, rc=0, `active` within 3 s. Works from `screenSaver` and from `readyToSuspend` (tested 63 s after locking). Prefer it to a second `powerButton 1`, which toggles and is state-dependent.
- **Timed wake from suspend:** works with the `readyToSuspend` recipe below. No button needed.

### Timed wake recipe (works)
1. Start a script that runs `lipc-wait-event -m com.lab126.powerd goingToScreenSaver,wakeupFromSuspend,readyToSuspend` and reads events.
2. On each `readyToSuspend` event call `lipc-set-prop -i com.lab126.powerd rtcWakeup <n>`. rc=0 every time. The event fires ~7 times, each set restarts the alarm, so the last set counts.
3. The device suspends and later emits `wakeupFromSuspend` in state `screenSaver`.

### What does not work (or surprised us)
| Attempt | Result |
|---|---|
| `rtcWakeup` while `active` | `lipcPropErrInvalidState` (rc=1) |
| `rtcWakeup` while `screenSaver` | `lipcPropErrInvalidState` (rc=1). Only accepted in `readyToSuspend` (as the community says) |
| `deferSuspend <n>` | `lipcErrNoSuchProperty` although `lipc-probe` lists it: unusable |
| Wake time follows the `rtcWakeup` value | No. 60 s and 30 s both woke the device 100-101 s after the last set (three runs: 101 s, 101 s, 100 s). Larger values untested. Treat the interval as ~100 s and not configurable until proven otherwise |
| Wi-Fi after timed wake while still locked | Never came up in 40 s: `cmState=NA`, no IP. Tried `lipc-set-prop com.lab126.cmd wirelessEnable 1`, `lipc-set-prop com.lab126.cmd ensureConnection wifi` (rc=0, no effect), and a `wirelessEnable 0 -> 1` toggle |
| Wi-Fi after `wakeUp 1` | `cmState=PENDING` immediately, SSH reachable ~3 s later. Network needs the `active` state |
| `nohup`, running scripts from `/mnt/us` directly | `nohup` does not exist (silent failure when stderr is redirected), `/mnt/us` blocks direct execution. Use `sh /mnt/us/script.sh >/dev/null 2>&1 &` |

### Consequence: no `lock` in v1 (decided 2026-11-15)
After `powerButton 1` a locked EY21 can talk to HA for about a minute, then it suspends and is unreachable. Timed wake exists but Wi-Fi does not return while locked, so a locked device cannot poll HA without going `active` (screen redraw each cycle, cost unmeasured). A `lock` switch would strand the device, so Control v1 does not offer it. Bringing it back: `docs/future/control-v2.md`.

## 5. Open experiments (not done, in suggested order)
Items 1-4 and 7 are lock/screensaver work (future, see `docs/future/control-v2.md`). Items 5 and 6 matter for v1.
1. Larger `rtcWakeup` values (e.g. 300, 900): does the wake time scale, or is ~100 s fixed?
2. The other project's route: `rtcwake -d /dev/rtc1 -m mem -s N` or writing `rtc1/wakealarm` plus `echo mem > /sys/power/state`, with Wi-Fi handled manually. `rtcwake` exists. Invasive, test with recovery route ready.
3. A wake-and-poll cycle: wake, `wakeUp 1`, connect, poll, re-lock with `powerButton 1`. Measure screen flash visibility and battery cost per cycle. This would enable remote unlock for a locked device (option B in the design discussion).
4. Quiet power measurement while locked and per cycle. A live SSH session distorts readings (about -29 mA active idle vs -47 to -86 mA locked were measured with SSH running, so not comparable). Log `battery_current` to a file on the device, then read it after waking.
5. ~~Eye-check flIntensity 0~~ (done by the user: 0 turns the light fully off). Still open: what `flEnable` does (used by the other project; not probed on this device, not present in `lipc-probe` output).
6. Read the `yoshi_battery0` nodes and `battTemperature` unit properly for the sensors.
7. Custom screensaver: would need a screensaver hack (e.g. linkss) to be installed. Not investigated.

## 6. How to re-run safely
- Follow `docs/probing-devices.md` (read-only first, recovery route, one write at a time, restore values).
- On-device experiment scripts must (a) be started with `sh`, (b) end by calling `lipc-set-prop com.lab126.powerd wakeUp 1` so the device is not left suspended, (c) be removed afterwards (`killall lipc-wait-event; rm /mnt/us/<script> /mnt/us/<log>`), and (d) log to a file, because the SSH session dies when the device suspends.
- Observe from the PC by polling TCP 22 (`bash -c 'exec 3<>/dev/tcp/<ip>/22'`), not ping.
- The device suspends by itself after ~10 min idle in `active` (powerd reports "Remaining time in this state"). For a longer probe session set `lipc-set-prop com.lab126.powerd preventScreenSaver 1` and restore it to `0` afterwards.
- If the device is stuck suspended with Wi-Fi off, a physical power-button press wakes it. A 40 s hold forces a reboot. USB-cable SSH is the fallback route.

## 7. References
- KOReader Kindle powerd driver: https://git.blob42.xyz/Archives/koreader/blame/commit/d9e4376e3594b7df97841fe70e94d03e5ff9382e/frontend/device/kindle/powerd.lua (`flIntensity`, `battLevel`, `isCharging`; `currentAmberLevel` is absent on the EY21)
- KindleCron (RTC wake in the `readyToSuspend` window): https://github.com/lennardollesch/KindleCron
- MobileRead: RTC wakeup KT4 https://www.mobileread.com/forums/showthread.php?t=322900, Online screensaver extension https://www.mobileread.com/forums/showthread.php?t=236104&page=5, Lipc wiki https://wiki.mobileread.com/wiki/Lipc
- HerrRiebmann/Kindle-Kual-Screensaver (own suspend cycle, `rtcwake`, Wi-Fi recovery, ~3-5% battery/day on a PW7 at 10-minute updates): https://github.com/HerrRiebmann/Kindle-Kual-Screensaver, discussed in https://community.home-assistant.io/t/kindle-e-ink-home-info-display/378002/12
- Display half of the same idea (server-side dashboard screenshot): https://github.com/sibbl/hass-lovelace-kindle-screensaver

## 8. Verified on the device for the Control agent (2026-11-15)
Everything below was run on this EY21 (BusyBox v1.17.1, built 2015-06-23).
- `/tmp` is a symlink to `/var/tmp`, a 32 MB tmpfs: RAM, safe for status files. `/` stays 88% full, never write there.
- `tr -d '\001-\037\177'` is NOT a range here (it deletes the hyphen and keeps the tab) and `tr -d '[:cntrl:]'` is NOT a class (it deletes the letters c n t r l). Use `sed 's/[[:cntrl:]]//g'` (sed classes work). `tr '\000' ' '` works (used to read `/proc/<pid>/cmdline`).
- `awk` `print` of an integer above 1e6 gives exponent form (`print 2147483648*2` -> `4.29497e+09`); `printf "%.0f"` is exact. Always `printf` computed numbers.
- `grep` has no `-E` and no `-x`; `timeout` exists but only as `timeout -t SECS cmd`; `sleep` takes integers only; shell arithmetic is 64-bit; `printf` padding, `read -r`, `${v##*) }`, quoted-pattern `${v#"$p"}` and `mkdir`-based locks all work.
- ash runs built-in applets (`ifconfig`, `df`, `uname`, `hostname`, ...) in preference to PATH lookups, so PATH stubs cannot shadow them (the host test stubs for those only work on the dev machine).
- `sh script.sh &` leaves `$!` pointing at a forked wrapper whose cmdline is the parent's, not the script's: a daemon must write its own pid (`$$`).
- `/etc/version.txt` first line: `System Software Version: 035-juno_6011_celeste_yoshime3-268989`. `lipc-get-prop com.lab126.wifid 711` prints `2.3 AP: <ssid> (<bssid>)`, `2.3.1   Signal: 5/5`, `2.3.4   Channel: 11`, `2.6 Country: AT`.
- All 22 readable Control capabilities returned plausible values (`cpu_usage` needs two reads).
- Setting brightness from HA (50 -> `flIntensity` 12, 0 -> 0, 13 -> 3), `keep_awake` on/off (`preventScreenSaver` 1/0) all round-trip; the agent recovers on its own from an HA restart, from HA reloading the integration after entities are enabled, and from a wrong passphrase (status `error: unauthorized (check token)`).
- Not verified yet: `eips -c` (refresh button), behaviour across suspend/wake, clock jumps after a reboot, Wi-Fi off/on, battery cost over time, `battery_temperature` unit.
