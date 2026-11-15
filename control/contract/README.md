# Control contract v1

Normative spec for the device-control wire protocol between a host and a device agent. Machine-readable parts: `catalog.json` (capabilities), `schema/<message>.schema.json`, `fixtures/valid|invalid/` (golden examples), `fixtures/passphrase-normalization.json`. Version history: `CHANGELOG.md`.

## Endpoints and auth

Base path `/api/panel_control/<device_id>/`. Every request carries `Authorization: Bearer <passphrase>`. Bodies are JSON, UTF-8.

| Request | Body | Response |
|---|---|---|
| `POST hello` | hello | hello-response |
| `POST state` | state | state-response |
| `GET commands?wait=<s>` | none | commands |
| `GET config` | none | config |

Errors: HTTP status plus `{"error": <code>, "detail": <text>}` (schema `error`, fixtures `valid/error-*.json`).

| Code | HTTP | When |
|---|---|---|
| `locked_out` | 429 | source IP has 10 bad tokens within 5 min |
| `unknown_device` | 404 | no such `<device_id>` |
| `unauthorized` | 401 | token missing or wrong |
| `unsupported_contract` | 400 | hello `contract` is not the integer `1` |
| `hello_required` | 409 | `state`, `commands` or `config` before any hello for this device |
| `invalid_payload` | 400 | body fails its schema |

Precedence: `locked_out`, `unknown_device`, `unauthorized`; then for hello `unsupported_contract` (checked before schema validation) before `invalid_payload`; for `state` `hello_required` before `invalid_payload`. `commands` and `config` have no body.

## Messages

| Message | Schema | Fixtures |
|---|---|---|
| hello | `schema/hello.schema.json` | `valid/hello-ey21.json`, `valid/hello-empty-capabilities.json` |
| hello-response | `schema/hello-response.schema.json` | `valid/hello-response-basic.json` |
| state | `schema/state.schema.json` | `valid/state-basic.json`, `valid/state-acks.json`, `valid/state-null-value.json` |
| state-response | `schema/state-response.schema.json` | `valid/state-response-basic.json` |
| commands | `schema/commands-response.schema.json` | `valid/commands-brightness.json`, `valid/commands-press-toggle.json`, `valid/commands-empty.json` |
| config | `schema/config.schema.json` | `valid/config-basic.json` |
| error | `schema/error.schema.json` | `valid/error-*.json` |

`invalid/` holds messages the schemas must reject. `wire-invalid/` holds messages the JSON Schema cannot reject (parsers accept `1e3` and `NaN`) but that break the compact wire rule; they are checked by raw text, not by schema.

## Semantics

- **Commands** are queued by the host as `{id, capability, value, issued_at}`. The host always emits `null` as the value of a value-less button (a press never carries a value). The queue keeps the latest per capability, drops commands older than 300 s (`sleep`: 30 s, so that a press made while the device was unreachable never fires after it comes back), and is in memory only. The host rejects commands for undeclared or disabled capabilities before queueing.
- **Ack:** the agent lists applied command ids in `acks` of its next `state`. `ok:false` in an ack is a warning only; the command is not retried.
- **Long poll:** `wait` is clamped to 0-55 s. An empty `commands` list means timeout.
- **state.time** is the agent's clock (epoch seconds); the host derives `clock_offset` from it.
- **hello** replaces the declared capability set. Capabilities removed by a new hello become unavailable. Heartbeat and hello are not capabilities and are always allowed.
- **hello_required:** if the host has no hello for this device (e.g. after restart) it answers `state` and `commands` with `409 hello_required`; the agent re-sends hello.
- **Availability:** follows last contact of any request. A device is unavailable after 3 missed heartbeats. Defaults (hello-response): `heartbeat_s` 60, `poll_wait_s` 25.
- **Enablement:** the host decides which declared capabilities are enabled. The agent reads and reports only enabled ones. Before the first config (and while the host is unreachable on start) it polls nothing; it keeps the last config while the host is unreachable.
- **config_rev:** carried by every config, `state` response and `commands` response. When it differs from the agent's copy, the agent fetches `GET config`. The host bumps it whenever the enabled set changes.
- **config.interval_s** lists every enabled capability whose catalog `report` is `interval` (value: its catalog `interval_s`) or `hello` (86400). Capabilities with `report` `change` or `none` are absent: the agent polls absent ones every loop and sends on change, and never reads write-only ones.
- Values are normalized to the catalog units. `state.values[x] = null` means the reading failed or is unknown; the host shows the entity as unknown. A value whose type does not match the capability is treated as null (unknown).
- **Virtual and write-only:** `clock_offset` is computed by the host on every `state` post as device clock minus host clock (seconds, sign device minus host) from the integer `state.time`; the agent never sends it and the host ignores one if sent. A write-only capability (e.g. `refresh_screen`, `sleep`) is never read by the agent and never appears in `state.values`.
- **Capability semantics:** `battery_current` negative = discharging; `memory_free` includes reclaimable memory (free + buffers + cache); `frontlight_on` is true when brightness > 0; `refresh_screen` is a value-less press (command `value` null), duplicates collapse in the queue. `sleep` is likewise a value-less press (command `value` null, duplicates collapse): the device enters its system sleep/lock state. It has no state to report and nothing to read. A device that cannot sleep while its keep-awake setting is on switches that setting off first, reported through the normal `keep_awake` state. The device may suspend and drop the network shortly afterwards and the host cannot wake it (a physical action on the device is required), so its entities become unavailable after 3 missed heartbeats. The press is acknowledged like any command: the agent acks right after applying it, before the device goes to sleep. It is one-way: there is no unlock and no state.

## Passphrase

Generated form: 5 lowercase words joined with `-`, e.g. `maple-orbit-tiger-quilt-ember`; the host stores and emits that form. Comparison form: lowercase, remove all whitespace (spaces, tabs, CR, LF) and `-`, then compare in constant time. Vectors: `fixtures/passphrase-normalization.json` (`normalized` is the comparison form); `fixtures/passphrase-malformed.json` lists inputs that are not 5 words. After 10 bad tokens from one source IP the host answers `429 locked_out` to that IP for 5 minutes.

## Compact wire rule

Responses the agent parses without a JSON library (hello-response, config, state-response, commands) are emitted on one line, no whitespace, with fixed key order:

- hello-response: `contract, heartbeat_s, poll_wait_s, config`
- config: `config_rev, enabled, interval_s`
- state-response: `config_rev`
- commands: `config_rev, commands`; each command: `id, capability, value, issued_at`

Command `value` is `null`, `true`, `false` or a plain decimal `-?[0-9]+(\.[0-9]+)?`: never an exponent, `NaN` or a string. The host formats numbers as plain decimals, at most 2 decimals, integral values as integers, never an exponent. Ids are `[a-z0-9]+`, capabilities `[a-z_]+`.

## Parsing commands without jq

Single source of truth for the agent's extractor; prints `<id> <capability> <value>` per command:

```sh
tr '}' '\n' | sed -n 's/.*"id":"\([a-z0-9]*\)","capability":"\([a-z_]*\)","value":\([^,]*\),.*/\1 \2 \3/p'
```
