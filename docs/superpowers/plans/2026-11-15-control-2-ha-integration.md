# Control HA integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A HACS-style custom integration `panel_control` that pairs a device by passphrase, serves the contract over authenticated HTTP views, and creates only the entities a device declares and the user enables.

**Architecture:** Pure-Python core (`passphrase`, `lockout`, `runtime`) with no HA imports and plain unit tests; thin HA layer on top (`views`, `config_flow`, entity platforms) tested with `pytest-homeassistant-custom-component` and a fake device client that replays the contract fixtures. The integration knows only the contract, never "Kindle".

**Tech Stack:** Home Assistant custom integration (current release), `pytest-homeassistant-custom-component`, `uv`. Stack is installed in `control/.venv` (Python 3.14, HA 2026.10.4, pytest 9.0.3, jsonschema 4.26; recreate with `uv venv --python 3.14 control/.venv && uv pip install --python control/.venv/bin/python pytest-homeassistant-custom-component jsonschema`). Run: `control/.venv/bin/python -m pytest control/tests -q`. `control/pytest.ini` must set `asyncio_mode = auto` (without it hass fixture tests error with `PytestRemovedIn9Warning`). `homeassistant` has no `__version__`; use `homeassistant.const.__version__`.

**Spec:** `docs/superpowers/specs/2026-11-08-device-controls-design.md`. Contract: `control/contract/` (plan 1, must be done first).

## Global Constraints

- Domain `panel_control`; code in `control/custom_components/panel_control/`; tests in `control/tests/`; `manifest.json` + `hacs.json` present; no import from `dashboard/` or from `control/contract/` at runtime.
- Endpoints (custom `HomeAssistantView`s, not HA webhooks) under `/api/panel_control/<device_id>/`: `POST hello`, `POST state`, `GET commands?wait=<s>`, `GET config`. `requires_auth = False` for HA's own auth; our bearer passphrase is checked instead.
- Passphrase: 5 words from the bundled 674-word list joined with `-` (about 47 bits); normalize = trim, lowercase, drop spaces and `-`; compare with `hmac.compare_digest`; 10 failures per source IP lock that IP out for 5 min (`429 locked_out`). Use `request.remote`, never `X-Forwarded-For`.
- Commands: in-memory queue, latest value per capability, drop after 300 s, refuse capabilities that are undeclared or disabled. Availability: unavailable after 3 missed heartbeats (default 60 s). `heartbeat_s` 60, `poll_wait_s` 25, long-poll `wait` clamped to 0-55 s.
- Entities: `control` and `sensor` categories enabled by default; `diagnostic` and `sensitive` disabled by default (`entity_registry_enabled_default=False`), diagnostics use `EntityCategory.DIAGNOSTIC`. `config_rev` = `zlib.crc32` of the canonical JSON of `{enabled, interval_s}` (sorted keys, compact), so it changes exactly when the enabled set changes and survives restarts.
- Sensitive values (`ip_address`, `ssid`, `mac_address`, `serial_number`) are never logged.

## Review Focus

- Passphrase typed with capitals, spaces or trailing newline still authenticates (Task 1, 4).
- Two devices created with the same name get distinct `device_id`s (Task 5).
- HA restart: restored entities show unavailable; `state`/`commands` before a new `hello` answer `409 hello_required` (Tasks 2, 4).
- `wait` that is negative, huge or not a number is clamped, not a 500 (Task 4).
- A `state` carrying a value for a disabled or undeclared capability is ignored, not stored (Task 2).
- Two concurrent `commands` long-polls from one device (agent restarted): the newer wins, the older returns an empty list (Task 4).
- `hello` with a changed capability set removes the entities that disappeared (marked unavailable) (Task 6).

---

### Task 1: Scaffold, catalog copy, passphrase

**Files:**
- Create: `control/custom_components/panel_control/{__init__.py,manifest.json,const.py,catalog.json,wordlist.txt,passphrase.py}`, `hacs.json` (at `control/`), `control/pytest.ini`, `control/tests/{conftest.py,test_catalog_sync.py,test_passphrase.py}`

**Interfaces:**
- Produces: `passphrase.generate() -> str` (hyphenated 5 words), `passphrase.normalize(raw: str) -> str` (compare form: lowercase, all whitespace and `-` removed), `passphrase.matches(stored: str, presented: str) -> bool`; `const.DOMAIN = "panel_control"`; `catalog.json` identical to `control/contract/catalog.json`.

- [ ] **Step 1: Write failing tests.** `test_catalog_sync`: file equals `control/contract/catalog.json` byte for byte. `test_passphrase`: wordlist has exactly 674 entries, all `[a-z]{3,7}`, unique, unique 3-letter prefixes; `generate()` returns 5 words from the list joined by `-`; `normalize` satisfies every vector in `control/contract/fixtures/passphrase-normalization.json`; `matches` is true for `" MAPLE orbit-Tiger quilt ember\n"` against `maple-orbit-tiger-quilt-ember`, false for a 4-word prefix and for `""`.
- [ ] **Step 2: Run, expect FAIL** (module missing).
- [ ] **Step 3: Implement.** `wordlist.txt` = the EFF short wordlist #2 filtered to words of 3-7 letters (674 of its 1296 words, hyphenated "yo-yo" excluded, CC BY 3.0, attribution and the filtering noted in `wordlist.NOTICE`); `generate` uses `secrets.choice`; `matches` normalizes both and uses `hmac.compare_digest`. Copy `catalog.json`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(control): panel_control scaffold, passphrase`

### Task 2: Runtime core (no HA imports)

**Files:**
- Create: `control/custom_components/panel_control/runtime.py`, `control/tests/test_runtime.py`

**Interfaces:**
- Consumes: `catalog.json`.
- Produces: `class DeviceRuntime` with
  `__init__(self, device_id: str, enabled_default: Callable[[str], bool], now: Callable[[], float] = time.time)`,
  `apply_hello(hello: dict) -> None` (replaces declared set, clears `needs_hello`),
  `needs_hello: bool` (True after `restore`),
  `restore(declared: list[dict]) -> None`,
  `config(enabled: set[str]) -> dict` (`{config_rev, enabled, interval_s}` per contract),
  `apply_state(state: dict, enabled: set[str]) -> dict[str, Any]` (returns accepted values, drops undeclared/disabled, records acks),
  `queue_command(capability: str, value) -> str` (returns id; raises `ValueError` for undeclared, disabled, or read-only capabilities and for out-of-range numbers),
  `take_commands() -> list[dict]` (compact contract form, drops >300 s),
  `async wait_commands(wait: float) -> list[dict]` (returns immediately if queue non-empty, else waits for a new command or timeout; a newer waiter makes the older return `[]`),
  `set_enabled(enabled: set[str]) -> None` (single source of truth for what is enabled; purges queued commands of newly disabled capabilities), `touch() -> None`, `available(heartbeat_s: int = 60) -> bool` (False before first contact and after 3 missed heartbeats),
  `clock_offset(device_time: int) -> int` (device clock minus host clock, seconds; computed on every `state` post, the host ignores a `clock_offset` value in `values`).

- [ ] **Step 1: Write failing tests** (fake clock): `test_hello_replaces_declared`, `test_restore_requires_hello`, `test_state_drops_disabled_and_undeclared`, `test_queue_latest_value_wins` (two brightness commands -> one with the latter value), `test_command_expires_after_300s`, `test_refuses_undeclared_disabled_readonly`, `test_number_out_of_range_rejected` (brightness 101), `test_press_collapses_duplicates` (`refresh_screen` twice -> one command), `test_config_rev_stable_and_changes` (same enabled set -> same rev, toggling one capability -> different rev), `test_config_intervals` (`interval` ids carry their catalog seconds, `hello` ids 86400, `change` and `none` ids absent from `interval_s` but present in `enabled`), `test_available_after_three_missed_heartbeats` (180 s -> unavailable at 181 s), `test_wait_commands_wakes_on_queue` and `test_second_waiter_supersedes_first` (asyncio), `test_clock_offset`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** with `asyncio.Event`/futures per waiter; command ids from a counter formatted `^[a-z0-9]{1,16}$`; acks stored as `last_acks` for the warning path (Task 6).
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(control): device runtime core`

### Task 3: Lockout

**Files:**
- Create: `control/custom_components/panel_control/lockout.py`, `control/tests/test_lockout.py`

**Interfaces:**
- Produces: `class Lockout`: `__init__(now=time.time, max_failures=10, window_s=300)`, `is_locked(ip: str) -> bool`, `record_failure(ip: str) -> None`, `record_success(ip: str) -> None`.

- [ ] **Step 1: Write failing tests:** `test_locks_after_ten_failures`, `test_unlocks_after_five_minutes`, `test_success_resets_counter`, `test_ips_independent`.
- [ ] **Step 2: Run, expect FAIL.** **Step 3: Implement** (dict of ip -> (count, locked_until)). **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(control): lockout`

### Task 4: HTTP views

**Files:**
- Create: `control/custom_components/panel_control/views.py`, `control/custom_components/panel_control/enablement.py` (`compute_enabled(hass, entry_id, runtime) -> set[str]`: for each declared capability, the entity-registry entry of unique id `<device_id>_<capability>` decides (enabled iff not disabled), unregistered ones use the catalog default; the `hello` view calls `runtime.set_enabled(compute_enabled(...))` right after `apply_hello`, because `set_enabled` is explicit and a capability new in a later hello would otherwise stay disabled), `control/tests/test_views.py`, `control/tests/fake_device.py`, `control/tests/test_enablement.py`
- Modify: `control/custom_components/panel_control/__init__.py` (register views, hold `hass.data[DOMAIN][entry_id] = (DeviceRuntime, Lockout, passphrase)`)

**Interfaces:**
- Consumes: `DeviceRuntime`, `Lockout`, `passphrase.matches`.
- Produces: `fake_device.FakeDevice(client, base: str, token: str)` with `hello(fixture)`, `state(values, acks=())`, `commands(wait=0)` returning `(status, json)`. All views answer with contract `error` bodies; every success body is validated against the contract schema inside `FakeDevice` (jsonschema, schemas read from `control/contract/schema`).

- [ ] **Step 1: Write failing tests** with a config entry fixture (device_id `kindle_test`, known passphrase): `test_hello_ok_returns_config`, `test_wrong_token_401_then_lockout_429` (10 bad tokens), `test_token_normalization_accepted`, `test_unknown_device_404`, `test_invalid_payload_400` (hello declaring `lock`), `test_unsupported_contract_400` (`contract: 2`), `test_state_before_hello_409`, `test_commands_before_hello_409`, `test_state_updates_and_returns_config_rev`, `test_commands_long_poll_returns_queued_command`, `test_commands_wait_clamped` (`wait=-5`, `wait=9999`, `wait=abc` all return 200 quickly with an empty list when nothing is queued, using a patched clamp for the 55 s ceiling), `test_responses_are_compact_fixed_order` (raw bodies of hello, state, commands and config equal `json.dumps(..., separators=(",",":"))` with the contract key orders), `test_concurrent_polls_newer_wins`, `test_config_endpoint`, `test_config_before_hello_409`, `test_error_precedence` (locked-out IP gets 429 even with a valid token; unknown device 404 before token check; bad token on a known device 401; `contract: 2` hello -> `unsupported_contract` not `invalid_payload`; state before hello -> 409 even when the body is also invalid), `test_command_value_formatting` (a float like `0.00001` or `1e16` queued for a number capability is emitted as a plain decimal rounded to at most 2 decimals, integral values as integers, never an exponent).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** four `HomeAssistantView` classes sharing one `_authenticate(request)` helper (resolve device by `device_id` in the URL, check `Lockout`, then `passphrase.matches`). Validate request bodies with the bundled catalog (ids, ranges) and the hello shape; do not depend on `jsonschema` at runtime. Serialize every success body with `json.dumps(separators=(",",":"))` and the contract key order via `web.Response(text=..., content_type="application/json")`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(control): contract HTTP views`

### Task 5: Config flow and pairing

**Files:**
- Create: `control/custom_components/panel_control/config_flow.py`, `strings.json`, `translations/en.json`, `control/tests/test_config_flow.py`

**Interfaces:**
- Produces: config entry `data = {"device_id": str, "passphrase": str, "name": str}`; unique id = `device_id`.

- [ ] **Step 1: Write failing tests:** `test_user_step_creates_entry` (name `Kitchen Kindle` -> `device_id` `kitchen_kindle`, passphrase has 5 words), `test_second_device_same_name_gets_distinct_id` (`kitchen_kindle_2`), `test_pairing_info_shown` (final step description placeholders contain the full URL `<base>/api/panel_control/<device_id>` and the passphrase), `test_options_flow_regenerates_passphrase`, `test_pairing_url_host_is_ip_when_no_internal_url` (the Kindle cannot resolve `.local` names, so with `internal_url` unset the shown URL uses the host IP; if `internal_url` is a hostname it is shown unchanged with a note).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** Step 1 asks for the name; step 2 (`pairing`, form with no fields) shows URL and passphrase via `description_placeholders`, entry is created on submit. URL from `homeassistant.helpers.network.get_url(hass, prefer_external=False)`. The options flow offers "regenerate passphrase" (updates entry data; the old one stops working immediately).
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(control): config flow with pairing info`

### Task 6: Entities and availability

**Files:**
- Create: `control/custom_components/panel_control/{entity.py,number.py,switch.py,button.py,sensor.py,binary_sensor.py,mapping.py}`, `control/tests/test_entities.py`
- Modify: `__init__.py` (call `runtime.set_enabled(...)` from the registry at setup and on every `EVENT_ENTITY_REGISTRY_UPDATED` for this device's entities, forward platforms, persist declared capabilities with `homeassistant.helpers.storage.Store`, `restore()` on startup, listen for `EVENT_ENTITY_REGISTRY_UPDATED` and store the current enabled set, availability tick every `heartbeat_s`)

**Interfaces:**
- Consumes: `DeviceRuntime`, catalog fields (`entity`, `category`, `sensitive`, `unit`, `min`, `max`, `values`).
- Produces: unique id `<device_id>_<capability_id>`; dispatcher signal `panel_control_update_<device_id>`; `mapping.HA_CLASS: dict[capability_id, dict]` (the only place HA device classes live: `battery_level`->battery, `charging`->battery_charging, `battery_temperature`->temperature, `battery_voltage`->voltage, `battery_current`->current in mA, `memory_*`/`storage_*`->data_size bytes, `uptime`/`clock_offset`->duration seconds, `wifi_signal` percent, `power_state` as enum sensor).

- [ ] **Step 1: Write failing tests** (FakeDevice drives hello/state): `test_only_declared_entities_created` (EY21 hello: no `warmth`, no `battery_temperature`, so 23 entities), `test_defaults_enabled_state` (`brightness`, `battery_level` enabled; `cpu_load`, `ip_address` disabled in the registry), `test_sensor_value_from_state`, `test_number_set_queues_command` (service `number.set_value` -> command appears on next `commands`), `test_button_press_queues_value_null`, `test_switch_keep_awake`, `test_refuses_when_unavailable_or_disabled`, `test_unavailable_after_missed_heartbeats` (freezer, 181 s), `test_restart_restores_entities_unavailable_until_hello`, `test_enabling_diagnostic_changes_config_rev_and_config_endpoint`, `test_hello_with_fewer_capabilities_marks_entities_unavailable`, `test_ack_failure_logs_warning_without_value` (`ok:false` acks produce a warning containing the capability id but never a sensitive value).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement** a `PanelEntity` base (`should_poll=False`, availability = `runtime.available()` and capability declared, dispatcher updates) and the five platforms driven by the catalog `entity` field, with `entity_registry_enabled_default = category in ("control","sensor") and not sensitive`. `clock_offset` is computed from `state.time` via `runtime.clock_offset`.
- [ ] **Step 4: Run all tests** `control/.venv/bin/python -m pytest control/tests -q` -> PASS.
- [ ] **Step 5: Commit** `feat(control): entities, availability, enablement`

### Task 7: Docs and packaging

**Files:**
- Create: `control/custom_components/panel_control/README.md`; Modify: `README.md` (repo root: one line linking it)

- [ ] **Step 1:** Write the README: install via HACS/custom_components copy, add the integration, copy URL + passphrase to the Kindle `config` file over USB (plan 3), enabling diagnostics, the LAN-HTTP note (token visible on the LAN, https via reverse proxy works because the base URL is configurable), passphrase lockout behavior, what happens after an HA restart.
- [ ] **Step 2:** Run `control/.venv/bin/python -m pytest control -q` (contract + integration) -> PASS.
- [ ] **Step 3: Commit** `docs(control): integration README`
