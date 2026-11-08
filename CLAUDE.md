# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

This repo has no code yet: only `README.md` and `TODO.md`, so there are no build, lint or test commands. It is a planned Home Assistant wall panel (first target: Kindle e-readers) inspired by 1RandomDev/kindle-smarthome-dashboard.

`TODO.md` is the idea collection and the source of direction. It is unsorted and not a committed plan. Read it before designing anything. Its main points:
- Render the real HA dashboard server-side (headless browser, e.g. Playwright), convert the screenshot to an e-ink grayscale image and send it to the Kindle. The Kindle only shows the image, sends taps (replayed as clicks server-side) and a heartbeat, because its old WebKit can't run the HA frontend.
- Other ideas: use the lockscreen to show dashboard snapshots, and expose Kindle controls and sensors (brightness, battery, etc.) as HA entities.
- KISS/YAGNI: keep image transfer as simple as possible (plain HTTP image fetch), with no diffing or extra protocols until a real need shows up.

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