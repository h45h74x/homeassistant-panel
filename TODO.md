# Idea collection / TODO

Unsorted ideas, not a committed plan.

> **Two independent products.** *Control* (`control/`: expose the device hardware to HA as entities) and *Dashboard* (`dashboard/`: show a real HA dashboard on the device) are separate HA integrations and separate apps/scripts on the device. Neither depends on the other, they share no code, no wire protocol and no auth. They live in one repo for now but must be splittable into two repos by moving a folder. Shared hardware facts (`devices/`, `docs/probing-devices.md`) are reference only, never imported.

> **Reminder: KISS, YAGNI.** Keep the actual image transfer as simple as possible (e.g. plain HTTP fetch of an image), so it is robust _because_ of its simplicity. No clever protocols, diffing or extra moving parts until a real need shows up.

## Dashboard (`dashboard/`)

### 1. Show a real Home Assistant dashboard on the Kindle

**Goal:** replace the hardcoded `mesquite/js/index.js` dashboard with an actual HA dashboard.

User flow:
1. Customize your own e-reader dashboard visually in Home Assistant.
2. Link your Kindle to your Home Assistant instance.
3. Show the optimized panel.

Requirements:
- Interactive but still resource-efficient.
- One dashboard to rule them all.
- No representations of cards, show the actual ones.
- Offload rendering and calculation to the HA instance (integration / add-on) if possible, while the page stays interactive.

**How to implement (thoughts):**
- The Kindle browser (Mesquite, old WebKit) can't run the HA frontend (modern JS, web components), so rendering has to happen server-side.
- Server-side headless browser (e.g. Chromium via Playwright) loads the real HA dashboard view.
- Screenshot is converted to an e-ink-friendly grayscale image (dithered or 16 grays) and sent to the Kindle, ideally only changed regions.
- Kindle app shrinks to: show image, send taps, heartbeat.
- Interactivity: Kindle sends tap coordinates, the server replays them as real clicks in the headless browser. HA's own frontend handles toggles, dialogs and state updates.
- Open: sliders, more-info popups and scrolling need drag/scroll forwarding. Decide how deep interactivity has to go.
- Package as an HA add-on (bundles Node and Chromium). Open: does it work on the user's HA install type (HA OS vs. container)?
- Replaces most of `99-kindle-display` and the hardcoded UI. Keep the KUAL launcher, backlight control and WebSocket link.
- Linking the Kindle: pairing via HA (token or URL entered on the Kindle, or shown as a code).
- Needs a way to pick or mark the e-reader dashboard/view in HA, plus per-device size and orientation.

### 2. Use the lockscreen (screensaver) to show dashboard snapshots

- Utilize and auto-update the current Kindle lockscreen so it shows snapshots of a dashboard.
- Reuses the same server-side rendering as item 1, with the Kindle pulling the image (a locked EY21 suspends and drops Wi-Fi, so the server cannot push).
- Makes the Kindle usable without the stay-awake mode, which drains the battery.
- Open: setting the screensaver image is a device action, but must not require the control app. Keep it inside the dashboard app (own Kindle script), even if that duplicates a bit of lipc/sysfs code.

## Control (`control/`)

### 3. Kindle system controls and sensors in Home Assistant

**Status: implemented** (contract, HA integration, Kindle agent; on-device verification pending), see `control/README.md`. The list below is the original idea collection.

Control (as HA entities):
- Brightness, and warmth (only on devices that support it).
- ~~Lock / unlock the screen from HA entities.~~ Dropped from v1 (the EY21 suspends and drops Wi-Fi after locking), see `docs/future/control-v2.md`.

Sensors:
- Battery.
- System version.
- Storage.
- Resource metrics (CPU, memory, etc.).

Notes:
- Own HA integration plus own Kindle agent (see `docs/superpowers/specs/2026-11-08-device-controls-design.md`). Later work: `docs/future/`. Does not use Mesquite, Utild or the dashboard.
- Anything the dashboard needs from the hardware (e.g. backlight) is done by the dashboard app itself, not via the control app.
- Check per-device capability detection (warmth, battery paths differ between models).
