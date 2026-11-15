# Device controls and sensors in Home Assistant (TODO #3)

Status 2026-11-15: implemented per `docs/superpowers/plans/2026-11-15-control-{1-contract,2-ha-integration,3-kindle-agent}.md`; Kindle-side on-device verification pending. Where implementation decisions differed from this text they are recorded in the plans (e.g. 674-word list, `set_enabled`, fire-once commands, the passphrase compare form) and in `control/contract/README.md`, which is normative.

Product: **Control**. Fully independent of the Dashboard product (TODO #1/#2): separate integration, separate Kindle app, separate folder, no shared code or protocol. One repo for now, two repos later.

## Intent
Expose a wall-panel device (first: Kindle Paperwhite 5th gen, EY21) to Home Assistant as a device with controls and sensors, so HA automations can dim it, change warmth, and read battery/system state. Why: the panel should be a normal HA citizen, and the same HA integration must later serve other devices (Android, other e-readers) without changes.

## Goals
- A device-agnostic contract (capabilities, state, commands) that stands first and is the only thing the HA integration knows.
- A custom HA integration (`custom_components/`) with a config flow ("main screen" = config flow + HA device page) creating entities only for capabilities a device declares.
- A Kindle Paperwhite 1 (EY21, MX50 Yoshime) agent plus a lipc/sysfs layer, started via KUAL, with no dependency on Mesquite, Utild or the dashboard.

## Non-goals
- Dashboard rendering (TODO #1) and lockscreen snapshots (TODO #2): a separate product, no coupling, no shared code.
- MQTT, an HA add-on.
- Any device other than the EY21. No paths or quirks for other Kindle models.
- `lock` in v1 (user decision 2026-11-15, see Calls: Lock).
- Diffing, custom protocols, auth schemes beyond a per-device token.
- A native on-device config UI (Jobman-style Slint app, KOReader plugin) and a search-bar connect command (impossible on the EY21, see Calls).

## Anti-goals
- Anything that opens a listening port on the Kindle (rooted device).
- Kindle-specific names, units or paths leaking into the contract or the integration.
- Heavy resource use on the Kindle: no busy loops, few and slow timers.

## Constraints
- Kindle side is POSIX `sh` plus `curl` (BusyBox), no frameworks. Wi-Fi sleeps when the screen is off, so the agent must tolerate failed requests and retry.
- Lipc names were verified read-only on the EY21 (see `devices/kindle-ey21/README.md`). The EY21 has no warmth (`currentAmberLevel` does not exist), so `warmth` is simply not declared for it. Brightness 0 turns the light fully off (confirmed by the user). BusyBox 1.17.1 has no `grep -E` and probably no `jq`.

## Approaches considered
- **A. Kindle pushes state to an HA endpoint and long-polls for commands (chosen).** Outbound-only, robust to NAT, HA restarts and Wi-Fi sleep; needs only `curl`.
- B. HA polls an HTTP server on the Kindle. Simplest HA side, but opens a port on a rooted device and breaks when Wi-Fi sleeps.
- C. MQTT discovery. Standard, but needs a broker; the user wants an integration.

## Design
Layout:
```
control/
  contract/                      # schema + docs (source of truth)
  custom_components/<name>/      # HA integration, contract only (own hacs.json when split out)
  devices/kindle-ey21/           # KUAL extension: agent.sh + ey21.sh (lipc/sysfs layer)
dashboard/                       # separate product, see TODO #1/#2
devices/kindle-ey21/             # shared hardware facts (README, probe-output): reference only
```
Contract (v1, JSON over HTTP, all requests carry a per-device token):
- `hello`: device id, contract version, agent version, the `device` identity block, and the declared capabilities with their catalog ids, types and ranges (see the catalog below). The response carries the current `config` (see Enablement).
- `state`: map capability to value, pushed on change and on a slow heartbeat.
- `commands`: HA queues `{capability, value}`; the agent long-polls, applies each command, and acknowledges it with the resulting state.
- Values are normalized in the contract (percent 0-100); the Kindle layer maps to native scales (e.g. amber 0-24).

### Capability catalog (part of the contract, device-agnostic)
Capabilities are defined once, here, in contract terms (normalized units, no device names or paths). A device layer declares the subset it supports in `hello`; HA creates entities only for those. Anything not in the catalog cannot be exposed: extend the catalog first, then the devices.

Categories decide the HA defaults. `control` and `sensor` entities are enabled by default. `diagnostic` entities use HA's `entity_category: diagnostic` and are **disabled by default**; the user enables the ones they want. `sensitive` ones (network identity) stay disabled by default and must never be logged.

| Capability id | Category | Entity | Access | Contract value | Default interval |
|---|---|---|---|---|---|
| `brightness` | control | number | read/write | percent 0-100 | on change |
| `warmth` | control | number | read/write | percent 0-100, only devices with an amber frontlight | on change |
| `keep_awake` | control | switch | read/write | boolean; on = no screensaver or suspend (battery heavy, off by default) | on change |
| `refresh_screen` | control | button | write | value-less `press`; clears e-ink ghosting. Duplicate presses collapse in the queue | n/a |
| `sleep` | control | button | write | value-less `press`; the device enters its system sleep/lock state. No state, nothing to read. The device may suspend and drop the network shortly after, the host cannot wake it (a physical action is needed), so its entities become unavailable after 3 missed heartbeats. Acked right after applying, before sleeping. One-way. Duplicate presses collapse in the queue | n/a |
| `battery_level` | sensor | sensor | read | percent 0-100 | 60 s |
| `charging` | sensor | binary sensor | read | boolean | 60 s |
| `frontlight_on` | diagnostic | binary sensor | read | true when brightness is above 0 | on change |
| `power_state` | diagnostic | sensor | read | `active` / `screensaver` / `suspended` (as far as the device can tell) | on change |
| `cpu_usage` | diagnostic | sensor | read | percent 0-100 over the last interval | 60 s |
| `cpu_load` | diagnostic | sensor | read | 1-minute load average | 60 s |
| `memory_total` | diagnostic | sensor | read | bytes | 3600 s |
| `memory_free` | diagnostic | sensor | read | bytes, reclaimable (free + buffers + cache) included | 60 s |
| `storage_total` | diagnostic | sensor | read | bytes, user storage | 3600 s |
| `storage_free` | diagnostic | sensor | read | bytes, user storage | 600 s |
| `rootfs_used_percent` | diagnostic | sensor | read | percent 0-100 of the system partition (low-space warning) | 3600 s |
| `clock_offset` | diagnostic | sensor | read | seconds, device clock minus HA clock (agent sends its time, HA computes) | 3600 s |
| `uptime` | diagnostic | sensor | read | seconds | 600 s |
| `battery_temperature` | diagnostic | sensor | read | degrees Celsius | 300 s |
| `battery_voltage` | diagnostic | sensor | read | volts | 300 s |
| `battery_current` | diagnostic | sensor | read | milliamps, negative = discharging | 300 s |
| `wifi_signal` | diagnostic | sensor | read | percent 0-100 | 300 s |
| `ip_address` | diagnostic, sensitive | sensor | read | text | 600 s |
| `ssid` | diagnostic, sensitive | sensor | read | text | 600 s |
| `mac_address` | diagnostic, sensitive | sensor | read | text | on hello |
| `kernel_version` | diagnostic | sensor | read | text | on hello |

Static identity is not an entity: `hello.device` carries `name`, `manufacturer`, `model`, `hw_version`, `sw_version` (firmware/OS version), and optionally `mac` and `serial_number`. HA puts these into the device registry. `mac` is used as the registry connection if present. `serial_number` is only sent if the user opts in on the device (privacy).

Each device documents which capabilities it supports, and how, in `devices/<id>/README.md` ("Supported features"). The device layer implements `get`/`set` per declared capability, normalizes to the contract unit, and never exposes anything outside the catalog. The generic agent never touches lipc, sysfs or any other device API directly.

### Enablement: the device only queries what HA has enabled
The source of truth is the HA entity registry (the user enables or disables entities in the HA UI). The agent must not read or report a disabled capability, so a disabled diagnostic costs the Kindle nothing.
- `config` is `{config_rev: int, enabled: [capability ids], interval_s: {id: seconds}}`. HA builds it from the entity registry (enabled entities of this device) plus the catalog's default intervals.
- The `hello` response carries the current `config`. `GET /api/<domain>/<device_id>/config` returns it on demand.
- Every `state` and `commands` response carries `config_rev`. When it differs from the agent's copy, the agent fetches `config` and applies it. HA bumps `config_rev` when the user enables or disables an entity of this device.
- The agent reads only enabled capabilities, only when their interval is due, and sends one batched `state` per heartbeat containing the due values. Controls report on change and when commanded.
- HA rejects commands for capabilities that are undeclared or disabled, before they are queued.
- Before the first `config` (and while HA is unreachable on start) the agent polls nothing. It keeps the last `config` in memory while HA is unreachable.
- Heartbeat and `hello` are always allowed. They are not capabilities.

HA integration: config flow creates the device and shows its base URL and token to paste into the agent config; entities (`number`, `switch`, `sensor`) are created from the `hello` capabilities; a device that has not reported in a while shows as unavailable. Diagnostic entities are created disabled (registry default off), and enabling one is what makes the agent start querying it.

Kindle layer: `agent.sh` does generic transport only (hello, push, long-poll, retry with backoff). A separate `ey21.sh` implements `get/set` per capability via lipc/sysfs. Swapping devices means writing a different layer behind the same contract.

## Future work
Lock, deferred capabilities, risky buttons and more devices: `docs/future/control-v2.md`. The Dashboard product: `docs/future/dashboard.md`.

## Left to the builder
Integration domain name (proposal: `panel_control`), word list contents, long-poll timeout and heartbeat intervals, exact sysfs/lipc fallbacks once verified on the device, test approach (contract schema validation plus a fake-device test for the integration).

## Calls made after builder review (builder may revisit, user to check)
- **Transport:** custom `HomeAssistantView`s only (not HA's built-in webhook, which is unauthenticated and not meant for long-polls). Each device has a token, checked as `Authorization: Bearer`. Endpoints under `/api/<domain>/<device_id>/`: `POST hello`, `POST state`, `GET commands?wait=<s>`.
- **Network:** the Kindle reaches HA directly on the LAN over plain HTTP by default. The base URL is configurable, so an `https://` reverse proxy works unchanged. The token is therefore visible on the LAN; acceptable for a home network, noted in the docs.
- **Commands:** each has an `id`; the agent acknowledges by sending the ids in its next `state` post. The queue is in memory only (lost on HA restart), keeps the latest value per capability, and drops commands older than 5 minutes so a night-time dim never applies hours later.
- **Capability changes:** every `hello` replaces the declared set. Entities for removed capabilities become unavailable, and no re-pairing is needed.
- **Availability:** follows the last contact (any request). The device is unavailable after 3 missed heartbeats (default heartbeat 60 s, so about 3 min; tune if Wi-Fi sleep makes it flap).
- **Packaging:** HACS-compatible layout (`hacs.json`), targeting the current HA release.
- **Lock: dropped from v1 (user decision 2026-11-15, supersedes "one-way first").** The system lock suspends the EY21 and drops Wi-Fi, so a `lock` switch would strand it. Not in the catalog, integration, agent or tests. A dark panel is brightness 0. Evidence in `devices/kindle-ey21/README.md`, the way back in `docs/future/control-v2.md`.
- **Contract form (user decision):** `control/contract/` holds a normative prose spec, one JSON Schema per message (`hello`, `hello-response`, `state`, `commands-response`, `config`, `error`) and golden example fixtures (valid and invalid, incl. the EY21 hello). The catalog above is the capability source of truth and is mirrored in the schema. HA integration, a fake device and the shell agent are all tested against the same fixtures.
- **Token = typed-by-hand passphrase:** 5 random lowercase words from a curated list (674 words: the EFF short wordlist #2 filtered to 3-7 letters and without hyphenated words (yo-yo), unique 3-letter prefixes and edit distance of at least 3, so no look-alike pairs) joined with `-`, e.g. `maple-orbit-tiger-quilt-ember` (about 47 bits). HA normalizes (trim, lowercase, spaces and `-` ignored), compares in constant time, and locks out a source IP for 5 min after 10 failed attempts to make up for fewer bits than a hex token. The contract states the normalization. The word list lives in the integration with a test for its properties.
- **Kindle config (user decision):** one plain `key=value` file (`url`, `token`, optional `device_name`) under `/mnt/us/extensions/`, editable over USB, with `config.sample`. KUAL menu: Start, Stop, Status (from a status file the agent writes), Show config (shown in plain text: the Kindle is trusted local hardware, user decision). The agent exits with a clear status line when the config is missing or invalid.
- **Search-bar connect command: dropped (probe 2026-11-15).** The installed `;log` dispatch takes exactly one argument, routes only `mrpi`/`runme`, and passes no arguments on, so a typed host and passphrase can never reach a script (details in `devices/kindle-ey21/README.md`). Config is the plain file edited over USB, plus the KUAL menu. The KPM repo does not help: it supports only `kindlepw2`/`kindlehf`.
- **Parsing without `jq` (probe 2026-11-15):** the EY21 has no `jq`, python or perl, but has `sed`, `awk`, `curl` 7.33, `timeout`, `flock`, `/usr/sbin/eips` and `lua` 5.1 with `cjson`. The contract still emits `commands` compactly with a fixed key order, so the agent parses with `sed` and needs nothing else; fixtures cover it. `lua`+`cjson` is the fallback if `sed` proves brittle. Call `eips` by full path.
