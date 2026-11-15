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

KUAL, menu "Panel Control": Start, Stop, Status, Show config (shows url and token in plain text). Results appear as a one-line message on the screen.

The agent does not start on boot: start it from KUAL after every reboot.

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
