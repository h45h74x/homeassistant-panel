# Panel Control for the Kindle Paperwhite 5 (EY21)

A small shell agent that runs on the Kindle and connects it to Home Assistant: it reports hardware state (battery, brightness, ...) and carries out commands (e.g. set brightness). Brightness 0 turns the light off. Contract: `control/contract/README.md`. Home Assistant side: see the README of the HA integration in `control/custom_components/`.

## Prerequisites

- Jailbroken Kindle with KUAL installed.
- Home Assistant with the Panel Control integration, and its pairing screen open (it shows the URL and the passphrase).

## Install

- `sh deploy.sh <ssh-host>` (GNU tar expected on the host) copies `panel-control/` to `/mnt/us/extensions/panel-control` (an existing `config` on the device is never touched), or
- copy the `panel-control/` folder to `extensions/` over USB.

Then copy `config.sample` to `config` (same folder) and fill in `url` and `token` from the HA pairing screen. `url` must contain an IP address, not a hostname: the Kindle cannot resolve `.local` names.

## Use

KUAL, menu "Panel Control": Start, Stop, Status, Status on screen: ON, Status on screen: OFF, Show config (shows url and token in plain text). Action results appear as a short message in a five-row block near the bottom of the screen (rows -10..-6, above the status display, so the Kindle status bar stays clear). Without `fbink` they fall back to the top rows via `eips`.

Show config draws the passphrase on the e-ink panel; it stays visible until the screen is redrawn and survives sleep and power-off, so redraw the screen afterwards.

`https://` URLs with self-signed certificates fail (curl rc 60): use the plain `http://` LAN URL. IPv6 literal addresses are untested.

The agent does not start on boot: start it from KUAL after every reboot.

## Sleep button

HA shows a button "Sleep" that locks the screen exactly like the power button. The Kindle suspends after about 30-60 s and goes unavailable in HA after about 3 minutes. HA cannot wake it: press the physical power button. After waking, the agent reconnects by itself within the backoff time (up to 2 minutes). Wall-panel tip: put a confirmation on the dashboard tap action.

## Status on screen

"Status on screen: ON" creates the flag file `/mnt/us/extensions/panel-control/display.on` and draws three lines on the bottom rows; "OFF" removes the flag and blanks them. While the flag exists the agent keeps the lines current:

1. `Panel Control: <state> <HH:MM:SS of the last contact>` (`no contact yet` before the first one)
2. and 3. the last two lines of the event log (older first).

- Event log: `/tmp/panel-control.log` (RAM, lines `HH:MM:SS message`, at most 60 lines then the newest 40 are kept). It holds short events only (`started`, `hello ok (N caps)`, `cmd brightness ok`, `HA unreachable, retry in 10s`, `unauthorized (check token)`, `online`), never the token or device identifiers. It is cleared by Stop, by Start and at reboot.
- Update rate: the display is redrawn only when the state or one of the two log lines changed, and at most once per 20 s (`PANEL_DISPLAY_MIN`), because every draw is a partial e-ink refresh. The clock part is refreshed only with such a redraw.
- It draws over whatever is on screen. The Kindle UI may redraw over it (page turn, sleep); it comes back with the next change. Stop draws `Panel Control: stopped` while the flag exists.
- The flag file is device state: `deploy.sh` never ships or removes it. The display persists across Start/Stop and reboots until switched OFF.
- Needs `fbink` (`/var/local/kmc/bin/fbink`, or `/mnt/us/libkh/bin/fbink`), which the jailbreak hotfix ships. Without it the display does nothing (no error).

## Status states

- `running`: connected, commands flow.
- `backoff`: Home Assistant is unreachable, the agent retries with growing delays.
- `error`: not usable (e.g. bad config); `last_error` says why.
- "STALE": the agent runs but has not reported contact for over 3 minutes.

## Troubleshooting

- `unauthorized`: wrong passphrase, check `token` against the pairing screen.
- `backoff`: HA is down or the URL/IP is wrong or changed.
- 409 responses (HA lost the session) recover automatically.
- "Not started ... create config": the `config` file is missing or invalid.
