# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

*Control* is implemented and reviewed, but not yet verified on the real device: the contract (`control/contract/`), the HA integration (`control/custom_components/panel_control/`) and the Kindle agent (`control/devices/kindle-ey21/`). The on-device verification and first deployment are the open step (plan `docs/superpowers/plans/2026-11-15-control-3-kindle-agent.md`, Task 5). *Dashboard* has no code yet, only planning notes in `docs/future/dashboard.md` and `TODO.md`. It is a Home Assistant wall panel (first target: Kindle e-readers) inspired by 1RandomDev/kindle-smarthome-dashboard.

Where things are:
- `docs/superpowers/specs/` approved designs, `docs/superpowers/plans/` the implementation plans (contract, HA integration, Kindle agent), `docs/future/` everything not in scope yet (lock, deferred capabilities, Dashboard). `TODO.md` is the unsorted idea collection.
- `devices/kindle-ey21/` hardware facts and probe outputs (reference only, never imported), `docs/probing-devices.md` how to probe a device safely.

Commands (from the repo root):
- HA integration and contract tests: `control/.venv/bin/python -m pytest control -q` (create the venv with `uv venv --python 3.14 control/.venv && uv pip install --python control/.venv/bin/python pytest-homeassistant-custom-component jsonschema`).
- Kindle shell suites (run under bash on the dev machine, they cannot run on the Kindle: they need python3 and `pgrep -f`): `PATH=control/.venv/bin:$PATH sh control/devices/kindle-ey21/tests/run.sh`.
- Build the installable output: `sh control/build.sh`. Interim dev HA: `sh control/dev-ha.sh start` and `control/.venv/bin/python control/dev_ha.py pair|states|call|enable` (see `control/README.md`).
- Deploy to the Kindle: `sh control/devices/kindle-ey21/deploy.sh <ssh-host>` (never ships or overwrites the device `config`).

`TODO.md` is still the source of direction for the Dashboard product. Its main points:
- Render the real HA dashboard server-side (headless browser, e.g. Playwright), convert the screenshot to an e-ink grayscale image and send it to the Kindle. The Kindle only shows the image, sends taps (replayed as clicks server-side) and a heartbeat, because its old WebKit can't run the HA frontend.
- Other ideas: use the lockscreen to show dashboard snapshots.
- KISS/YAGNI: keep image transfer as simple as possible (plain HTTP image fetch), with no diffing or extra protocols until a real need shows up.

## Architecture principle: two independent products

*Control* (HA integration + Kindle agent that exposes hardware as entities) and *Dashboard* (HA integration/add-on + Kindle app that shows a real HA dashboard) are separate integrations and separate apps/scripts on the device. They live in one repo for now, separated by folders, and will one day be two repos. So:
- Layout: `control/` and `dashboard/`, each with its own `contract/`, HA side and device side (`kindle-ey21/`). Nothing is imported across the two folders, and they share no wire protocol, token or code.
- Shared hardware facts (`devices/<id>/`, `docs/probing-devices.md`) are reference docs only. If both products need the same lipc call, each owns its own copy.
- Each must work with the other absent. Splitting the repo = moving one folder (plus its docs).

## Architecture principle (per product): device-agnostic and modular

Devices must be exchangeable (Kindle first, later maybe Android or other e-readers). So:
- Define the device-agnostic contract of each product first (entity/capability model, wire protocol between HA and a device agent). The HA integration and the main screen only know the contract, never a device.
- Device specifics (Kindle lipc/sysfs paths, KUAL packaging, model quirks) live in a device-specific layer behind that contract, in its own folder.
- Capabilities are declared per device (e.g. warmth, lock), and HA only creates entities for what a device reports.
- Currently the only supported device is the Kindle Paperwhite 5th gen (EY21). Do not add paths or quirks for other models yet.

## Developing for the Kindle (low-power e-ink device)

These apply to code that runs on the Kindle itself, not to the server side.

- Keep the Kindle thin: do filtering, gap-filling, date normalization and aggregation in the proxy and send small, ready-to-render payloads. Subscribe only to the entities and events the page needs.
- Use ES5 and old-WebKit CSS. No modern JS or CSS features, and no frameworks.
- E-ink has slow refresh and ghosting. Avoid animations and transitions (the chart uses `animation: { duration: 0 }`). Update the DOM only on real changes, and prefer small targeted updates over re-rendering whole lists. `refreshScreen()` (a white flash) clears ghosting.
- Keep timers few and slow. Weather polls every 2h, and the clock reschedules itself to the next minute boundary rather than polling each second.
- Keep the connection cheap but robust: the app-level `ping`/`pong` heartbeat detects dead sockets, and on close the app reconnects after 10s. The proxy re-subscribes to HA after reconnects.
- Prefer small SVG icons and the already-bundled `chart.min.js`. Avoid large images and new heavy libraries.
- Backlight is set by writing to sysfs via Utild (`kindle.messaging`). Keep it dim or off by default to save battery and respect night mode.
- Because the app prevents standby, the battery drains fast; the README describes a battery-less power mod.