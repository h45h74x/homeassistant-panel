# Control

Exposes a wall-panel device (first: Kindle Paperwhite 1, EY21) to Home Assistant as a device with controls (brightness, keep awake, refresh screen) and sensors (battery, memory, storage, Wi-Fi, ...). Independent of the Dashboard product: no shared code or protocol.

| Part | Where | What |
|---|---|---|
| Contract | [contract/](contract/README.md) | The device-agnostic wire contract: capability catalog, JSON Schemas, golden fixtures, normative prose. The only thing the HA side and a device agent share. |
| HA integration | [custom_components/panel_control/](custom_components/panel_control/README.md) | Custom integration (`panel_control`): pairing by passphrase, HTTP endpoints, entities created from what the device declares and the user enables. |
| Kindle agent | [devices/kindle-ey21/](devices/kindle-ey21/README.md) | KUAL extension: a small shell agent plus the EY21 hardware layer, configured by a plain `config` file. |

How it works: the device only makes outbound requests. It says hello (declared capabilities), pushes state on change and on a heartbeat, and long-polls for commands. HA never connects to the device.

Design: [docs/superpowers/specs/2026-11-08-device-controls-design.md](../docs/superpowers/specs/2026-11-08-device-controls-design.md). Not in scope yet (lock, more capabilities, other devices): [docs/future/control-v2.md](../docs/future/control-v2.md).

Tests: `control/.venv/bin/python -m pytest control -q` (HA integration and contract), `PATH=control/.venv/bin:$PATH sh control/devices/kindle-ey21/tests/run.sh` (Kindle shell suites).

## Build, install, try it

One build output is installed everywhere, so what you test is what a real HA gets:

- `sh control/build.sh` -> `control/dist/custom_components/panel_control/` (copy this folder into `<HA config>/custom_components/`) and `control/dist/panel_control.zip` (the same files at the zip root). Deterministic, git-ignored.
- Interim dev Home Assistant on this machine (uses the venv, config in git-ignored `control/.dev-ha/`, always installs the build output): `sh control/dev-ha.sh start|restart|stop|status|reset|logs`; `control/.venv/bin/python control/dev_ha.py pair [NAME]` adds the integration and prints the Kindle's `config` lines (`url=` and `token=`), `... states` lists the entities, `... call number.set_value '{"entity_id":"number.kindle_brightness","value":50}'` calls a service, `... enable|disable cpu_load ...` toggles entities. Seeded login for tests and interactive use: `admin` / `admin` (override with `DEV_HA_PASS`); open `http://<this machine's LAN IP>:8123` in a browser. It listens on the LAN so the Kindle can reach it: `sh control/dev-ha.sh stop` when you are not using it. First start installs HA's requirements into the venv (a minute or two), including the packages HA imports for service validation (`dev_ha_deps.py`); two voice-assistant packages without a Python 3.14 wheel are replaced by import stubs in `control/dev-stubs/` (dev instance only). Without those the web UI would load forever; `dev-ha.sh start` runs `dev_ha.py check` and reports `web UI backend ok`.
- Kindle: `sh control/devices/kindle-ey21/deploy.sh <ssh-host>`, then create `/mnt/us/extensions/panel-control/config` from the pairing output (see the Kindle README).

HACS: HACS expects `custom_components/<domain>/` at the repository root and one integration per repository (docs: hacs.xyz/docs/publish/integration), so this monorepo layout cannot be added to HACS as is. `sh control/export-hacs-repo.sh <dir>` writes a HACS-ready tree (same files as the build output, plus `hacs.json` and README) into a small separate repo; the step-by-step is in the main [README](../README.md#install-on-a-real-home-assistant). When Control is split into its own repo (planned, see `CLAUDE.md`) the separate repo is no longer needed.
