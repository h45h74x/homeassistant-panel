# Home Assistant Panel

Intuitive, versatile and configure wallpanel application for Home Assistant.

> Inspired by [1RandomDev/kindle-smarthome-dashboard](https://github.com/1RandomDev/kindle-smarthome-dashboard), all credit for the original project goes to them.

## Two independent products

- **Control** (`control/`): exposes the device hardware (brightness, battery, system sensors, ...) to Home Assistant as entities. Implemented: see [control/README.md](control/README.md).
- **Dashboard** (`dashboard/`): shows a real HA dashboard on the device. Not started: see [docs/future/dashboard.md](docs/future/dashboard.md).

Each has its own HA integration and its own app/script on the device, and works without the other. They share one repo for now and are meant to be split into two repos later.

## Install on a real Home Assistant

Needs: HA 2026.10+ (tested on 2026.10.4), a jailbroken Kindle PW1 (EY21) with KUAL and SSH (alias `kindle-pw1`), and HA reachable from the Kindle **by IP** (it cannot resolve `.local` names).

**A. HACS** (HACS only installs from a repo with `custom_components/panel_control/` at its root, so publish the build output as a small public repo once; same files as the dev HA runs)
- Create, export, publish (from this repo's root; the clone goes next to it):
  ```sh
  cd .. && gh repo create h45h74x/ha-panel-control --public --clone && cd homeassistant-panel
  sh control/export-hacs-repo.sh ../ha-panel-control
  cd ../ha-panel-control && git add -A && git commit -m "v0.1.0" && git branch -M main && git push -u origin main && gh release create v0.1.0 --generate-notes && cd ../homeassistant-panel
  ```
- HA: HACS -> menu (top right) -> Custom repositories -> `https://github.com/h45h74x/ha-panel-control`, type Integration -> Add -> open "Panel Control" -> Download -> restart Home Assistant.
- Update later: bump `version` in `control/custom_components/panel_control/manifest.json`, rerun the last two lines of the block above (export + publish) with the new version (`-m "v0.1.1"`, `gh release create v0.1.1`), then HACS -> Panel Control -> Update -> restart HA.

**B. Without HACS**
- `sh control/build.sh && scp -r control/dist/custom_components/panel_control <user>@<ha-host>:/config/custom_components/` (HA OS: SSH/Samba add-on, `/config/custom_components/`), restart HA.

**Pair (either way)**
- Settings -> Devices & services -> Add integration -> "Panel Control" -> name it (e.g. `Kindle`) -> note the **URL** and the **5-word passphrase** on the next screen -> Submit.
- The URL must contain an IP. If it shows a hostname or a note, use `http://<HA-IP>:8123/api/panel_control/<device_id>`.

**Kindle**
- `sh control/devices/kindle-ey21/deploy.sh kindle-pw1`
- ```sh
  printf 'url=%s\ntoken=%s\n' 'http://<HA-IP>:8123/api/panel_control/kindle' 'word-word-word-word-word' | ssh kindle-pw1 'cat > /mnt/us/extensions/panel-control/config'
  ```
- KUAL -> Panel Control -> Start. Status shows `running` and, in HA, device "Kindle" with its entities appears within a minute. "Status on screen: ON" shows state and log at the bottom of the screen.
- Diagnostics are off by default: enable the ones you want in HA (entity -> Settings -> Enabled); the Kindle starts reporting them by itself.
- After a Kindle reboot start it again from KUAL (no autostart yet).

## Development

### Devices

Development is done on the following devices:
- Kindle Paperwhite 5th gen (EY21) 
- Kindle Paperwhite 12th gen. 

Only the Kindle Paperwhite 5th gen (EY21) is supported so far; hardware facts are in [devices/kindle-ey21/README.md](devices/kindle-ey21/README.md).

## Docs

- Designs: [docs/superpowers/specs/](docs/superpowers/specs/), implementation plans: [docs/superpowers/plans/](docs/superpowers/plans/), later work: [docs/future/](docs/future/), safe device probing: [docs/probing-devices.md](docs/probing-devices.md), ideas: [TODO.md](TODO.md).