# Control contract v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Freeze the device-agnostic Control contract (catalog, message schemas, wire rules, golden fixtures) that the HA integration (plan 2) and the Kindle agent (plan 3) are both built and tested against.

**Architecture:** `control/contract/` is data plus prose plus one pytest file. `catalog.json` is the single machine-readable source for capabilities. JSON Schemas for each message reference it. Fixtures are golden valid/invalid payloads. No code is imported by the other plans, only these files are read (or copied, with a sync test).

**Tech Stack:** JSON Schema draft 2020-12, Python 3 + `pytest` + `jsonschema`, run with `control/.venv/bin/python -m pytest control/contract` (venv described in plan 2; `control/pytest.ini` from plan 2 Task 1 can be created here instead).

**Spec:** `docs/superpowers/specs/2026-11-08-device-controls-design.md`

## Global Constraints

- Contract version is the integer `1`. Base path `/api/panel_control/<device_id>/`. Endpoints: `POST hello`, `POST state`, `GET commands?wait=<s>`, `GET config`. Header `Authorization: Bearer <passphrase>`.
- No Kindle, lipc, sysfs or HA names in the contract. Values are normalized (percent 0-100, bytes, seconds, volts, milliamps, degrees Celsius).
- No `lock` capability anywhere. Catalog has exactly the 25 capabilities in the spec table (no more, no fewer).
- Defaults: `heartbeat_s` 60, `poll_wait_s` 25, command TTL 300 s, unavailable after 3 missed heartbeats.
- Every response the agent parses (`hello-response`, `config`, `state` response, `commands-response`) is compact single-line JSON with a fixed key order: `hello-response` `contract, heartbeat_s, poll_wait_s, config`; `config` `config_rev, enabled, interval_s`; `state` response `config_rev`; `commands-response` `config_rev, commands`, each command `id, capability, value, issued_at` (the EY21 agent parses with `sed`, there is no `jq`). Command values are number, boolean or null only (never strings).
- `config.interval_s` lists every enabled capability whose catalog `report` is `interval` (its `interval_s`) or `hello` (86400). Capabilities with `report` `change` or `none` are absent: the agent polls absent ones every loop and sends on change, and never reads write-only ones.
- Passphrase: 5 lowercase words joined with `-`; HA normalizes (trim, lowercase, remove spaces and `-`).

## Review Focus

- `hello` declares an id that is not in the catalog (e.g. `lock`): rejected, `invalid_payload`. Test in Task 2.
- `hello` with an empty `capabilities` list: valid (device with nothing to expose). Task 2.
- `state` with `null` for a value (unknown), and with an id not declared: schema accepts null, unknown ids are an HA runtime concern (plan 2). Task 2 pins null.
- A `commands` response with a pretty-printed or reordered fixture must fail the wire-format test, so a future change cannot silently break `sed` parsing. Task 3.
- Numbers like `1e3`, `NaN`, or a string in a command `value`: rejected. Task 3.

---

### Task 1: Catalog

**Files:**
- Create: `control/contract/catalog.json`, `control/contract/tests/test_catalog.py`

**Interfaces:**
- Produces: `catalog.json` = `{"version": 1, "capabilities": [Capability, ...]}` in the spec table's row order. `Capability` = `{id: str, category: "control"|"sensor"|"diagnostic", sensitive: bool, entity: "number"|"switch"|"button"|"sensor"|"binary_sensor", access: "r"|"rw"|"w", type: "number"|"boolean"|"text"|"enum"|"none", unit: str|null, min: number|null, max: number|null, values: [str]|null, report: "interval"|"change"|"hello"|"none", interval_s: int|null}`. Plans 2 and 3 read these field names.

- [ ] **Step 1: Write the failing test** `test_catalog.py` with: `test_ids_match_spec` (the 25 ids from the spec table, in order, no `lock`), `test_ids_unique`, `test_report_interval_consistency` (`interval_s` is int iff `report == "interval"`), `test_sensitive_only_network_identity` (exactly `ip_address`, `ssid`, `mac_address`), `test_brightness_range` (`brightness` and `warmth`: type number, unit `%`, min 0, max 100, access `rw`), `test_power_state_enum` (`values == ["active","screensaver","suspended"]`), `test_refresh_screen_is_value_less_button` (entity `button`, access `w`, type `none`).
- [ ] **Step 2: Run to verify it fails** (`catalog.json` missing): `control/.venv/bin/python -m pytest control/contract/tests/test_catalog.py -q` -> FAIL.
- [ ] **Step 3: Write `catalog.json`** from the spec table. Intervals as in the table: `battery_level`/`charging`/`cpu_usage`/`cpu_load`/`memory_free` 60; `storage_free` 600; `uptime`/`ip_address`/`ssid` 600; `memory_total`/`storage_total`/`rootfs_used_percent`/`clock_offset` 3600; `battery_*`, `wifi_signal` 300; `mac_address`, `kernel_version` report `hello`; controls and `frontlight_on`, `power_state` report `change`; `refresh_screen` report `none`. Units: `%`, `B`, `s`, `°C`, `V`, `mA`; `cpu_load` unit null.
- [ ] **Step 4: Run to verify it passes** -> all PASS.
- [ ] **Step 5: Commit** `git add control/contract && git commit -m "feat(control): contract catalog v1"`

### Task 2: Message schemas and fixtures

**Files:**
- Create: `control/contract/schema/{hello,hello-response,state,state-response,commands-response,config,error}.schema.json`, `control/contract/fixtures/valid/*.json`, `control/contract/fixtures/invalid/*.json`, `control/contract/tests/test_schemas.py`

**Interfaces:**
- Consumes: `catalog.json` ids (schemas hold a literal `enum` of the ids; `test_schema_ids_match_catalog` keeps them in sync).
- Produces (field names plans 2 and 3 use):
  - `hello` request: `{contract: 1, agent_version: str, device: {name, manufacturer, model, sw_version: str, hw_version?: str, mac?: str, serial_number?: str}, capabilities: [{id, min?: number, max?: number}]}`
  - `hello-response`: `{contract: 1, heartbeat_s: int, poll_wait_s: int, config: Config}`
  - `config`: `{config_rev: int, enabled: [id], interval_s: {id: int}}`
  - `state` request: `{time: int (device unix seconds), values: {id: number|boolean|string|null}, acks: [{id: str, ok: bool, error?: str}]}`; response (`state-response` schema) `{config_rev: int}`
  - `commands-response`: `{config_rev: int, commands: [{id: str ^[a-z0-9]{1,16}$, capability: id, value: number|boolean|null, issued_at: int}]}`
  - `error`: `{error: "unauthorized"|"unknown_device"|"hello_required"|"invalid_payload"|"unsupported_contract"|"locked_out", detail?: str}` (HTTP 401, 404, 409, 400, 400, 429)

- [ ] **Step 1: Write the failing test** `test_schemas.py` parametrized over fixture files: every file in `fixtures/valid/<message>-*.json` validates against `schema/<message>.schema.json`, every file in `fixtures/invalid/<message>-*.json` fails. Plus `test_schema_ids_match_catalog`. Fixture names encode the message: the schema is the longest schema name that is a prefix of the file name followed by `-` (so `hello-response-basic.json` maps to `hello-response`, not `hello`; `state-response-basic.json` to `state-response`).
- [ ] **Step 2: Run to verify it fails** (no schemas) -> FAIL.
- [ ] **Step 3: Write schemas and fixtures.** Valid: `hello-ey21` (the EY21 capability set from `devices/kindle-ey21/README.md`: no `warmth`, and no `battery_temperature` because its unit is unverified; `serial_number` absent), `hello-empty-capabilities`, `hello-response-basic`, `state-basic`, `state-null-value`, `state-acks`, `commands-brightness`, `commands-empty`, `config-basic`, `error-*` (one per code). Invalid: `hello-lock-capability`, `hello-unknown-contract-version` (`contract: 2`), `hello-missing-device`, `state-values-not-object`, `commands-string-value`, `commands-bad-id`, `error-unknown-code`. Use `additionalProperties: false` everywhere except where noted.
- [ ] **Step 4: Run to verify it passes** -> all PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(control): contract message schemas and fixtures"`

### Task 3: Wire format, passphrase vectors, prose spec

**Files:**
- Create: `control/contract/README.md`, `control/contract/CHANGELOG.md`, `control/contract/fixtures/passphrase-normalization.json`, `control/contract/tests/test_wire_format.py`

**Interfaces:**
- Produces: `passphrase-normalization.json` = `[{"input": str, "normalized": str}, ...]` (HA tests assert `normalize(input) == normalized`); `README.md` = normative prose.

- [ ] **Step 1: Write the failing test** `test_wire_format.py`: `test_agent_parsed_fixtures_are_compact` (every valid `hello-response-*`, `config-*`, `state-response-*` and `commands-*` fixture is one line, parses, has the key order from Global Constraints, and re-serializing with `json.dumps(separators=(",",":"))` reproduces the file text); `test_commands_sed_extractable` (apply the agent's field-extraction regexes, given in `README.md` under "Parsing commands without jq", to the fixture and compare with the parsed JSON); `test_command_values_numeric_form` (invalid fixtures with `1e3` and `NaN` values are rejected by the schema, so the schema must pattern-restrict numbers: add them as `invalid/commands-exponent.json`, `invalid/commands-nan.json`); `test_passphrase_vectors` (each `normalized` matches `^[a-z]+(-[a-z]+){4}$` for well-formed inputs, e.g. `" Maple Orbit-TIGER quilt  ember "` -> `maple-orbit-tiger-quilt-ember`).
- [ ] **Step 2: Run to verify it fails** -> FAIL.
- [ ] **Step 3: Write `README.md`** covering: endpoints and auth; every message with a fixture reference; semantics (commands queue latest-per-capability, TTL 300 s, ack by id in next `state`, `ok:false` is a warning with no retry; availability; `hello` replaces the declared set; `409 hello_required` when HA has no hello for this device, agent re-sends hello; `config` and `config_rev` enablement rules from the spec; long-poll `wait` clamped to 0-55 s; `time` in `state` feeds `clock_offset`); passphrase format and normalization (point at the vectors); the compact commands wire rule and the sed regexes; `locked_out` 429 after 10 bad tokens per source IP for 5 min. Write `CHANGELOG.md` with `1 - initial`. Add the two invalid exponent/NaN fixtures and tighten the `commands-response` number pattern in the schema.
- [ ] **Step 4: Run all contract tests** `control/.venv/bin/python -m pytest control/contract -q` -> all PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(control): contract wire rules, passphrase vectors, prose spec"`
