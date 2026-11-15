# Dashboard product (not started)

Independent of Control: own HA integration/add-on, own Kindle scripts, no shared code, wire protocol or token. See `CLAUDE.md` for the two-product rule. Source ideas: `TODO.md` #1 and #2. Nothing is decided; this lists what a brainstorm must settle.

## Idea
Build a dashboard in HA, link the Kindle, show that real dashboard. A server-side headless browser (Playwright) renders the HA view, the screenshot becomes an e-ink grayscale image, the Kindle fetches it over plain HTTP (KISS: no diffing, no custom protocol until needed). The Kindle shows the image, sends taps (replayed as clicks server-side) and a heartbeat.

## Two usage modes, probably two designs
| | #1 Interactive | #2 Lockscreen snapshot |
|---|---|---|
| Kindle state | awake, powered | asleep, battery |
| Update | server-side render on change, Kindle polls | Kindle wakes, pulls, shows |
| Input | taps, maybe drag/scroll | none |
| Hard part | interactivity depth (sliders, more-info popups) | reaching a suspended device |

## Facts that constrain it (from the EY21 probes)
- The Kindle suspends 30-60 s after the system lock and drops Wi-Fi, so the server cannot push to a locked device. #2 needs the Kindle to pull, after a wake. RTC wake is unverified (see [control-v2.md](control-v2.md) item 1).
- No custom screensaver mechanism installed (no `linkss`).
- About 12 MB free RAM, 2012 WebKit, ES5 only. One image fetch fits; the HA frontend does not.
- Reference implementations: `~/Userdata/Git/kindle-smarthome-dashboard` (hardcoded Mesquite UI, KUAL, backlight via Utild, WebSocket) and `~/Userdata/Git/Kindle-Kual-Screensaver` (KUAL extension fetching a PNG dashboard image, drawn with FBInk, suspend/wake loop in `auto.sh`). The second is the closest prior art for #2.

## Open questions
- Usage mode first: always-on interactive (#1) or snapshot (#2)? Which gets built first?
- HA install type: does an add-on with Chromium work on it (HA OS vs container)?
- Interactivity depth for #1: taps only, or drag and scroll forwarding?
- Pairing and dashboard/view selection, per-device size and orientation.
- Where the image is rendered and cached, and the refresh rule (interval vs on change).
- Screensaver setting must live inside the Dashboard app (own Kindle script), even if lipc/sysfs code is duplicated from Control.
