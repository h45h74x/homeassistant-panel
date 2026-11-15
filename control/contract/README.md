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

Errors: HTTP status plus `{"error": <code>, "detail": <text>}` (schema `error`). Codes and fixtures: `unauthorized` (401), `unknown_device` (404), `unsupported_contract` (400), `invalid_payload` (400), `hello_required` (409), `locked_out` (429); see `fixtures/valid/error-*.json`.

## Messages

| Message | Schema | Fixtures |
|---|---|---|
| hello | `schema/hello.schema.json` | `valid/hello-ey21.json`, `valid/hello-empty-capabilities.json` |
| hello-response | `schema/hello-response.schema.json` | `valid/hello-response-basic.json` |
| state | `schema/state.schema.json` | `valid/state-basic.json`, `valid/state-acks.json`, `valid/state-null-value.json` |
| state-response | `schema/state-response.schema.json` | `valid/state-response-basic.json` |
| commands | `schema/commands-response.schema.json` | `valid/commands-brightness.json`, `valid/commands-empty.json` |
| config | `schema/config.schema.json` | `valid/config-basic.json` |
| error | `schema/error.schema.json` | `valid/error-*.json` |

`invalid/` holds messages the schemas must reject. `wire-invalid/` holds messages the JSON Schema cannot reject (parsers accept `1e3` and `NaN`) but that break the compact wire rule; they are checked by raw text, not by schema.

## Semantics

- **Commands** are queued by the host as `{id, capability, value, issued_at}`. The queue keeps the latest per capability, drops commands older than 300 s, and is in memory only. The host rejects commands for undeclared or disabled capabilities before queueing.
- **Ack:** the agent lists applied command ids in `acks` of its next `state`. `ok:false` in an ack is a warning only; the command is not retried.
- **Long poll:** `wait` is clamped to 0-55 s. An empty `commands` list means timeout.
- **state.time** is the agent's clock (epoch seconds); the host derives `clock_offset` from it.
- **hello** replaces the declared capability set. Capabilities removed by a new hello become unavailable. Heartbeat and hello are not capabilities and are always allowed.
- **hello_required:** if the host has no hello for this device (e.g. after restart) it answers `state` and `commands` with `409 hello_required`; the agent re-sends hello.
- **Availability:** follows last contact of any request. A device is unavailable after 3 missed heartbeats. Defaults (hello-response): `heartbeat_s` 60, `poll_wait_s` 25.
- **Enablement:** the host decides which declared capabilities are enabled. The agent reads and reports only enabled ones. Before the first config (and while the host is unreachable on start) it polls nothing; it keeps the last config while the host is unreachable.
- **config_rev:** carried by every config, `state` response and `commands` response. When it differs from the agent's copy, the agent fetches `GET config`. The host bumps it whenever the enabled set changes.
- **config.interval_s** lists every enabled capability whose catalog `report` is `interval` (value: its catalog `interval_s`) or `hello` (86400). Capabilities with `report` `change` or `none` are absent: the agent polls absent ones every loop and sends on change, and never reads write-only ones.
- Values are normalized to the catalog units.

## Passphrase

Format: 5 lowercase words joined with `-`, e.g. `maple-orbit-tiger-quilt-ember`. The host normalizes the presented token before comparing in constant time: trim, lowercase, remove spaces and `-`. Vectors: `fixtures/passphrase-normalization.json` (`normalize(input) == normalized` for each, ignoring the `-` placement in `normalized`). After 10 bad tokens from one source IP the host answers `429 locked_out` to that IP for 5 minutes.

## Compact wire rule

Responses the agent parses without a JSON library (hello-response, config, state-response, commands) are emitted on one line, no whitespace, with fixed key order:

- hello-response: `contract, heartbeat_s, poll_wait_s, config`
- config: `config_rev, enabled, interval_s`
- state-response: `config_rev`
- commands: `config_rev, commands`; each command: `id, capability, value, issued_at`

Command `value` is `null`, `true`, `false` or a plain decimal `-?[0-9]+(\.[0-9]+)?`: never an exponent, `NaN` or a string. Ids are `[a-z0-9]+`, capabilities `[a-z_]+`.

## Parsing commands without jq

Single source of truth for the agent's extractor; prints `<id> <capability> <value>` per command:

```sh
tr '}' '\n' | sed -n 's/.*"id":"\([a-z0-9]*\)","capability":"\([a-z_]*\)","value":\([^,]*\),.*/\1 \2 \3/p'
```
