# Control Kindle agent (EY21) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A KUAL extension for the Kindle Paperwhite 1 (EY21) that pairs with the HA integration through a plain config file, reports only the capabilities HA has enabled, and applies brightness, keep-awake and refresh commands.

**Architecture:** One single-process shell loop, `agent.sh`, does transport only (hello, state push, long-poll, backoff) and knows nothing about lipc. A device layer, `ey21.sh`, is sourced and implements five shell functions. JSON is built and parsed with `sed`/`tr` against the contract's compact fixed-order responses. No background processes, no listening port.

**Tech Stack:** POSIX `sh` on BusyBox 1.17.1 ash, `curl` 7.33, `sed`, `awk`, `tr`. Dev-side tests: `sh` (or `busybox sh` if installed), a stdlib Python mock HA server using `jsonschema` from `control/.venv` (run tests with `PATH=control/.venv/bin:$PATH sh control/devices/kindle-ey21/tests/run.sh`).

**Spec:** `docs/superpowers/specs/2026-11-08-device-controls-design.md`. Contract: `control/contract/` (plan 1). Hardware facts: `devices/kindle-ey21/README.md`, probe: `devices/kindle-ey21/step0-output.txt`.

## Global Constraints

- Shell must run on BusyBox 1.17.1 ash: no `grep -E`, no `nohup`, no arrays, no `[[ ]]`, no `${v//a/b}`, no process substitution, `sed` basic regex only (no `\|`, `\+`, `-E`). No `jq`, python or perl on the device.
- Call `/usr/sbin/eips` by full path. Write only to `/tmp` (RAM) and `/mnt/us`; never to `/`. Start the agent with `sh script >/dev/null 2>&1 &` (no `nohup`, and `/mnt/us` blocks direct execution).
- Config: one `key=value` file at `/mnt/us/extensions/panel-control/config` (`url`, `token`, optional `device_name`, optional `send_serial=1`). `url` is the full endpoint base HA shows, e.g. `http://ha.local:8123/api/panel_control/kitchen_kindle`. The file is parsed, never sourced. The passphrase is shown in plain text (trusted device).
- Facts from the finished integration (plan 2): every request sends `Authorization: Bearer <token>`; HA answers `404 unknown_device` transiently during its reload after an entity is enabled/disabled and `409 hello_required` until the device re-sends hello — treat any non-200 as a failure with backoff, and on 409 re-send hello; `429 locked_out` waits 300 s; `state.time` must be an integer in 0..4102444800; hello capability ids must all be catalog ids (an unknown id makes hello fail with 400 forever), `min`/`max` finite numbers, device strings at most 200 characters, `agent_version` a string; a state value whose type does not match the capability (a string for a number capability) is treated by HA as unknown, so send numbers as numbers, booleans as booleans and `null` when a read fails; a `wait=0` poll supersedes any in-flight poll, so the loop's poll wait is `max(1, min(poll_wait_s, seconds to next due))` and the agent never spins.
- Timings come from HA's `hello` response (defaults 60 s heartbeat, 25 s poll). Backoff 5 s doubling to 120 s, reset on success; `401` waits 60 s, `429` waits 300 s. No timer other than the loop's own sleeps and `curl --max-time`.
- Declared EY21 capabilities: all catalog ids except `warmth`, `battery_temperature` (unit unverified) and anything that fails on-device verification in Task 5. `refresh_screen` is declared only if `eips -c` is verified harmless in Task 5.
- Status file `/tmp/panel-control.status`, pid file `/tmp/panel-control.pid`. The agent does not start on boot (KUAL Start only, see Open).
- Never log or display `serial_number`, `ip_address`, `ssid`, `mac_address` values.

## curl facts (verified on the EY21, 2026-11-15, against a LAN test server)

- Works: `-sS -m <s> --connect-timeout <s> -o <file> -D <file> -H ... --data-binary @- -w '%{http_code}'`, `-f`, keep-alive, chunked bodies, a body piped on stdin (`echo ... | curl --data-binary @-`).
- A held long-poll of `wait=25` returned at 25.1 s and `wait=55` at 55.1 s (`-m 35`/`-m 65`), the connection survives over Wi-Fi; a command released after 3 s arrived at 3.05 s.
- Exit codes the agent must handle: `28` timeout (also an unreachable host, 4 s with `--connect-timeout 3`), `7` connection refused (immediate), `52` empty reply (connection reset), `6` could not resolve host, `22` with `-f` on HTTP >= 400. On any curl failure `%{http_code}` prints `000`. Without `-f` an HTTP 502 HTML page returns rc 0 with code 502, so the agent must test the code, not just rc.
- Use `-m = wait + 10` for the long-poll and `-m 10 --connect-timeout 5` for other calls.
- **Hostnames:** the Kindle cannot resolve `<host>.local` (mDNS) or bare LAN names (`Could not resolve`), only what its DHCP DNS (the router) serves. The `url` in the config should be an IP address unless the router resolves the name. HA's pairing screen should show the IP-based URL (plan 2 Task 5 has the test).

## Device layer interface (Tasks 2-3 share this)

`ey21.sh` is sourced by `agent.sh` (path in `$DEVICE_LAYER`, default next to the agent) and defines:
- `dev_identity` prints `key=value` lines: `name`, `manufacturer`, `model`, `sw_version`, optional `hw_version`, `mac`, `serial_number`.
- `dev_capabilities` prints one line per declared capability: `<id>` or `<id> <flag>` with flag `w` (write-only, never read) or `v` (virtual: declared, never read, HA computes it, e.g. `clock_offset`).
- `dev_get <id>` prints the normalized value (`true`/`false`, a number, or text) and returns 0, or returns 1 when it cannot be read (the agent sends `null`).
- `dev_set <id> <value>` applies a command (`press` for value-less buttons); returns 0, or non-zero with a one-line reason on stdout. It clamps numbers to the catalog range.

## Review Focus

- Config edited on a Mac/Windows computer: CRLF line endings, a BOM-free file with quotes around values, spaces around `=`, trailing `/` on `url`. Parsed correctly (Task 1).
- HA or a reverse proxy returns an HTML error page or an empty body: treated as a failed request with backoff, loop never crashes (Task 2).
- Wi-Fi is down when the agent starts: retries with backoff, status shows the error (Task 2).
- A command for a capability the agent did not declare or a brightness of 250: acked `ok:false`, or clamped to 100, never a lipc call with a wild value (Tasks 2, 3).
- One `dev_get` failing must not stop the other values or the loop (Task 2).
- Start pressed twice: second start reports "already running" and does not spawn a second agent (Task 4).

---

### Task 1: Test harness, JSON helpers, config loader

**Files:**
- Create: `control/devices/kindle-ey21/panel-control/bin/lib.sh`, `control/devices/kindle-ey21/tests/{run.sh,t_lib.sh}`, `control/devices/kindle-ey21/tests/fixtures/config-crlf`

**Interfaces:**
- Produces in `lib.sh` (all print to stdout, return 0 unless stated):
  `json_str <text>` (quoted and escaped `\`, `"`, tabs/newlines removed),
  `json_val <raw>` (`true|false` and numbers `^-?[0-9]+(\.[0-9]+)?$` unquoted, empty -> `null`, otherwise `json_str`),
  `json_int <key> <body>` (value of `"key":<int>`),
  `parse_commands <body>` (one line per command: `<id> <capability> <value>`; `value` is `null`, `true`, `false` or a number),
  `parse_config <body>` (lines `rev <int>`, `enabled <id> <id> ...`, `interval <id> <seconds>` one per entry),
  `load_config <file>` (sets shell variables `CFG_URL`, `CFG_TOKEN`, `CFG_NAME`, `CFG_SERIAL`; returns 1 and prints a reason if `url` or `token` is missing or `url` does not start with `http://` or `https://`).
- `run.sh` runs every `t_*.sh` with `sh` (or `busybox sh` when `TEST_SH=busybox`), prints failures, exits non-zero on any.

- [ ] **Step 1: Write failing tests** in `t_lib.sh` using a tiny `assert_eq name expected actual` helper: `json_str` escaping of `a"b\c`; `json_val` for `true`, `-12`, `1.5`, `5.6.1` (string), empty (`null`); `parse_commands` on `control/contract/fixtures/valid/commands-brightness.json` and on a two-command body; `parse_config` on `config-basic.json`; `json_int heartbeat_s` on `hello-response-basic.json`; `load_config` on a CRLF file with `url = "http://ha:8123/api/panel_control/k/"`, `token = Maple-Orbit-Tiger-Quilt-Ember`, a comment line and a blank line -> `CFG_URL=http://ha:8123/api/panel_control/k`, `CFG_TOKEN=Maple-Orbit-Tiger-Quilt-Ember`; `load_config` fails for a missing token, and for `url=ha:8123`.
- [ ] **Step 2: Run** `sh control/devices/kindle-ey21/tests/run.sh` -> FAIL (`lib.sh` missing).
- [ ] **Step 3: Implement `lib.sh`.** Extraction relies on the contract's compact fixed-order rule: split commands with `tr '}' '\n'`, then one `sed -n 's/.*"id":"\([a-z0-9]*\)","capability":"\([a-z_]*\)","value":\([^,]*\),.*/\1 \2 \3/p'`. `load_config` reads with `tr -d '\r'`, ignores blanks and `#`, trims spaces around `key`/`value`, strips one pair of surrounding quotes, strips a trailing `/` from `url`.
- [ ] **Step 4: Run** -> PASS.
- [ ] **Step 5: Commit** `feat(control): kindle agent JSON helpers and config loader`

### Task 2: Agent loop against a mock HA

**Files:**
- Create: `control/devices/kindle-ey21/panel-control/bin/agent.sh`, `control/devices/kindle-ey21/tests/{mock_ha.py,fake_device.sh,t_agent.sh}`

**Interfaces:**
- Consumes: `lib.sh`, the device layer interface above.
- Produces: `agent.sh` reads `$PANEL_CONFIG` (default `/mnt/us/extensions/panel-control/config`), `$DEVICE_LAYER`, `$PANEL_STATUS` (default `/tmp/panel-control.status`), `$PANEL_BACKOFF_BASE` (default 5); exits 2 with status `error=<reason>` on bad config; runs forever otherwise. Status file lines: `state=running|backoff|error`, `last_contact=<epoch>`, `last_error=<text>`, `agent_version=0.1.0`.
- `mock_ha.py <scenario.json> <port-file> <log-file>`: stdlib HTTP server. Each endpoint answers from a scripted list of `{status, body}` (last one repeats), appends every request (`method path headers body`) to the log, and validates every request body against `control/contract/schema` with `jsonschema`, writing violations to the log as `SCHEMA-ERROR`.
- `fake_device.sh`: layer with `brightness` (backed by a file), `battery_level`, `cpu_load` (fixed), `refresh_screen w`, `clock_offset v`; `dev_set` records calls to a file.

- [ ] **Step 1: Write failing tests** in `t_agent.sh` (each starts the mock, runs `agent.sh` in the background for a few seconds with `poll_wait_s: 1`, `heartbeat_s: 2`, kills it, asserts on the mock log): `test_hello_then_state`, `test_hello_body_has_catalog_ids_only_and_no_warmth`, `test_state_only_enabled_ids` (config enables `brightness` only -> state values contain only `brightness`), `test_state_includes_time_and_not_virtual_or_write_only`, `test_interval_respected` (interval 60 for `cpu_load` -> sent once in 4 s), `test_command_applied_and_acked` (commands response with brightness 40 -> `dev_set` called with 40, next state has `acks:[{"id":"c1","ok":true}]` and brightness 40), `test_undeclared_command_acked_not_ok`, `test_dev_get_failure_sends_null`, `test_config_rev_change_fetches_config` (state response rev 2 -> `GET config` seen, new enabled set used), `test_409_triggers_new_hello`, `test_html_error_body_backoff_no_crash` (HTTP 502 with `<html>` -> status `state=backoff`, agent still alive, `PANEL_BACKOFF_BASE=1`), `test_unreachable_server_backoff`, `test_401_sets_error_status`, `test_bad_config_exit_2`, `test_no_schema_errors` (log has no `SCHEMA-ERROR` in any scenario).
- [ ] **Step 2: Run** `PATH=control/.venv/bin:$PATH sh control/devices/kindle-ey21/tests/run.sh` -> FAIL.
- [ ] **Step 3: Implement `agent.sh`.** One loop: hello (retry with backoff) -> apply config (`enabled`, intervals) -> repeat { collect due values (interval ids by per-id `due_<id>` variables via `eval`, other enabled ids read every loop and sent only if different from `last_<id>`; skip `w`/`v` ids) ; POST state if values, acks pending, or heartbeat elapsed ; GET commands with `wait=min(poll_wait_s, seconds to next due/heartbeat)` and `curl --max-time wait+10` ; apply commands through `dev_set`, re-read the capability, queue acks ; compare `config_rev` in every state/commands response }. All curl calls go through one `http_call <method> <path> [body-file]` that sets `HTTP_CODE` and `HTTP_BODY`, treating non-200 or curl failure as failure.
- [ ] **Step 4: Run** -> PASS.
- [ ] **Step 5: Commit** `feat(control): kindle agent transport loop`

### Task 3: EY21 device layer

**Files:**
- Create: `control/devices/kindle-ey21/panel-control/bin/ey21.sh`, `control/devices/kindle-ey21/tests/{t_ey21.sh,stubs/bin/{lipc-get-prop,lipc-set-prop,df,ifconfig,uname,eips},fixtures/proc/*,fixtures/sys/*}`

**Interfaces:**
- Consumes: the device layer interface. Env `PROC_ROOT` (default `/proc`) and `SYS_ROOT` (default `/sys`) redirect file reads; stubs on `PATH` replace commands and log set calls to `$STUB_LOG`.
- Produces: `ey21.sh` implementing the five functions per `devices/kindle-ey21/README.md` "Supported features".

- [ ] **Step 1: Write failing tests** using values from `devices/kindle-ey21/probe-output.txt` as fixtures: `test_brightness_get_rounds` (`flIntensity` 3 -> 13), `test_brightness_set` (50 -> `lipc-set-prop com.lab126.powerd flIntensity 12`; 250 -> clamped to 24 sent as 100% -> `24`; -5 -> `0`), `test_battery_and_charging`, `test_power_state_mapping` (`active`->`active`, `screenSaver` and `readyToSuspend`->`screensaver`), `test_frontlight_on`, `test_keep_awake_get_set` (`preventScreenSaver` 0/1, set `true`/`false` -> 1/0), `test_cpu_load`, `test_memory_free_bytes` (MemFree+Buffers+Cached kB x 1024), `test_memory_total_bytes` (256180 kB -> 262328320), `test_storage_bytes_from_df`, `test_rootfs_used_percent` (88), `test_uptime`, `test_battery_voltage_volts` (4071 -> 4.071), `test_battery_current_ma`, `test_wifi_signal_percent` (`5/5` -> 100, `3/5` -> 60), `test_kernel_version` (`2.6.31-rt11-lab126`), `test_ip_and_mac_parse`, `test_cpu_usage_first_null_then_percent` (two fake `/proc/stat` samples), `test_unknown_id_returns_1`, `test_capabilities_exclude_warmth_and_battery_temperature`, `test_capabilities_flags` (`refresh_screen w`, `clock_offset v`), `test_identity_model_and_version` (`Kindle Paperwhite 1 (EY21)`, `sw_version` from `System Software Version:` line), `test_serial_only_when_opted_in`.
- [ ] **Step 2: Run** -> FAIL.
- [ ] **Step 3: Implement `ey21.sh`.** Rounding: `pct = (n*100 + 12) / 24` and `n = (v*24 + 50) / 100` in shell arithmetic. Use `awk` for kB->bytes (values exceed 32-bit shell ints on larger devices) and for the `/proc/stat` delta (keep the last sample in a variable). `ssid` and `wifi_signal` parse the `lipc-get-prop com.lab126.wifid` outputs listed in the README. `refresh_screen` calls `/usr/sbin/eips -c` through `$EIPS` (stub in tests).
- [ ] **Step 4: Run** -> PASS.
- [ ] **Step 5: Commit** `feat(control): EY21 device layer`

### Task 4: KUAL packaging, start/stop/status, deploy

**Files:**
- Create: `control/devices/kindle-ey21/panel-control/{config.xml,menu.json,config.sample}`, `.../bin/{start.sh,stop.sh,status.sh,show-config.sh}`, `control/devices/kindle-ey21/deploy.sh`, `control/devices/kindle-ey21/tests/t_launcher.sh`, `control/devices/kindle-ey21/README.md`

**Interfaces:**
- Produces: KUAL menu entries Start, Stop, Status, Show config, each calling the matching script and showing a one-line result with `/usr/sbin/eips` (`$EIPS` override in tests); `deploy.sh <ssh-host>` copies `panel-control/` to `/mnt/us/extensions/panel-control` via `ssh host 'tar x -C /mnt/us/extensions' < tar` and never overwrites an existing `config`.

- [ ] **Step 1: Write failing tests** in `t_launcher.sh` (stub `eips`, temp dirs for pid/status/config via env): `test_start_creates_pidfile_and_runs`, `test_second_start_says_already_running_and_single_process`, `test_stop_kills_and_removes_pidfile`, `test_stop_when_not_running_is_ok`, `test_start_without_config_reports_missing_config` (message tells the user to create `config` from `config.sample`), `test_status_prints_state_and_last_contact`, `test_show_config_prints_plain_text`.
- [ ] **Step 2: Run** -> FAIL.
- [ ] **Step 3: Implement.** `start.sh` checks the pid file with `kill -0`, validates the config via `load_config`, launches `sh agent.sh >/dev/null 2>&1 &`, stores `$!`. `config.sample` has commented `url`, `token`, `device_name`, `send_serial`. `config.xml`/`menu.json` follow KUAL's format (copy the structure from `/mnt/us/extensions/usbnet` on the device). The README documents: install, edit config over USB, copy URL and passphrase from HA, Start from KUAL, what the status means.
- [ ] **Step 4: Run** `sh control/devices/kindle-ey21/tests/run.sh` -> all PASS.
- [ ] **Step 5: Commit** `feat(control): KUAL extension, launcher scripts, deploy`

### Task 5: On-device verification and end-to-end (manual, user go-ahead, NOT delegated)

Manual with the real EY21 and a real HA dev instance (`control/.venv/bin/hass -c <tmp config dir>` with `control/custom_components/panel_control` symlinked in). Probe rules: `docs/probing-devices.md` (one write at a time, restore values, recovery route ready). Order from the final review:

- [ ] **Step 0a: is `/tmp` RAM?** `ls -ld /tmp; readlink /tmp; df /tmp /var/tmp; free`. The probe's `df` shows tmpfs only for `/dev`, `/dev/shm`, `/var`. If `/tmp` is on `/` (88% full flash) switch `PANEL_STATUS`, `PANEL_PID`, `PANEL_TMP` and the cpu sample file to a RAM path (`/var/tmp`) before anything else.
- [ ] **Step 0b: applet probes** (copy-paste on the device): `printf 'a-b\tc\001d' | tr -d '\001-\037\177'` (expect `a-bcd`; if the hyphen is gone the range form is wrong), `echo 'a b' | tr -d '[:cntrl:]'`, `tr '\000' ' ' </proc/$$/cmdline | grep -q sh`, `awk 'BEGIN{print 2147483648*2, 1234567+0}'`, `printf '%-5.5s|\n' ab`, `printf '\357\273\277' | hexdump -C`, the real `${v#"$p"}` BOM form, `cat /etc/version.txt`, `lipc-get-prop com.lab126.wifid 711`, `hostname`, `uname -r`, `sh -c 'sleep 1; date +%s'`, `timeout` usage (`timeout -t 1 sleep 5`?).
- [ ] **Step 0c: run the shell suites under the device's BusyBox** (RAM only): copy `tests` and `panel-control` to `/tmp/pc-test`, run `t_lib.sh` and the stub-based parts of `t_ey21.sh` there (`t_agent.sh`, `t_launcher.sh` and the integration part of `t_ey21.sh` need python3/`pgrep -f`/`seq`/`pgrep -P`, which the Kindle lacks: they cannot run there). For the real agent under BusyBox run `mock_ha.py` on the dev machine and point the Kindle's agent (config and `PANEL_*` in /tmp, real `ey21.sh`) at it over the LAN; the mock log must contain no `SCHEMA-ERROR`. Fix any BusyBox 1.17 incompatibility, then `rm -rf /tmp/pc-test`.
- [ ] **Step 1: verify the unverified device facts** over SSH, read-only first: `ssid` parse (`wifid 711` real text), `sw_version` parse (real `/etc/version.txt`), `cpu_usage`, `uptime`, `mac_address`, `battery_temperature` unit (compare with a known temperature; leave undeclared if unknown). Record in `devices/kindle-ey21/README.md` "Supported features"; remove any capability that fails from `dev_capabilities`.
- [ ] **Step 2: `eips -c`**: with the stock UI showing, run it once. If the screen stays blank or the UI does not recover, remove `refresh_screen` from `dev_capabilities`; check the `eips` argument order and that the `say` rows 0-4 overlay the KUAL UI sensibly.
- [ ] **Step 3: deploy and pair:** `sh control/devices/kindle-ey21/deploy.sh kindle-pw1`; add the integration in HA, copy URL (IP!) and passphrase into `config`, KUAL Start. Expected: device appears in HA with up to 23 entities (diagnostics disabled), brightness and battery update within a minute.
- [ ] **Step 4: exercise it:** set brightness 50 then 0 (light off, then restore), enable `cpu_load` (reporting within one heartbeat), press refresh, toggle `keep_awake` (restore off), restart HA (409 then automatic hello), enable/disable an entity (transient 404/409, automatic recovery), Wi-Fi off/on (backoff then recovery), wrong passphrase (status unauthorized; five wrong attempts stay below the lockout of 10).
- [ ] **Step 5: leaks and timing:** while polling `ps | grep curl` and `cat /proc/<curlpid>/cmdline` (no token); `ls -l /tmp/panel-control.d` (0700 dir, `curl.cfg` 0600); after `kill -9` Start then Stop once and confirm the dir is gone; `time sh stop.sh` (expect < 3 s); no orphan `curl`/`sleep`; Start twice quickly; Start after `kill -9` of the agent.
- [ ] **Step 6: power and clock:** power button -> screensaver -> suspend -> wake (does HA go unavailable and recover? does `date` jump?); reboot, Start immediately, watch for a clock jump; leave KUAL, plug/unplug USB, reboot (no autostart); note battery drop and agent CPU (`top -n1`) over 30 minutes.
- [ ] **Step 7: config edge cases:** CRLF and BOM config created on a PC and copied over USB; a token containing `"`. Record findings and commit `docs(control): EY21 verification results`.

## Open

- Autostart on boot is not planned in the spec; the agent stops on reboot. Added to `docs/future/control-v2.md` as a candidate.
- Idle battery cost of the long-polling agent is unmeasured.
