# Idea collection / TODO

Unsorted ideas, not a committed plan.

> **Reminder: KISS, YAGNI.** Keep the actual image transfer as simple as possible (e.g. plain HTTP fetch of an image), so it is robust _because_ of its simplicity. No clever protocols, diffing or extra moving parts until a real need shows up.

## 1. Show a real Home Assistant dashboard on the Kindle

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

## 2. Use the lockscreen (screensaver) to show dashboard snapshots

- Utilize and auto-update the current Kindle lockscreen so it shows snapshots of a dashboard.
- Reuses the same server-side rendering as item 1, with the image pushed to the Kindle on a schedule or on change.
- Makes the Kindle usable without the stay-awake mode, which drains the battery.

## 3. Kindle system controls and sensors in Home Assistant

Control (as HA entities):
- Brightness, and warmth (only on devices that support it).
- Lock / unlock the screen from HA entities.

Sensors:
- Battery.
- System version.
- Storage.
- Resource metrics (CPU, memory, etc.).

Notes:
- Likely a small HA integration (or MQTT discovery) fed by the Kindle through the existing Utild / `kindle.messaging` path. Backlight is already set via sysfs.
- Check per-device capability detection (warmth, battery paths differ between models).
