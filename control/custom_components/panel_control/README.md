# Panel Control

Home Assistant integration that exposes the hardware of a wall-panel device (brightness, battery, and so on) as entities. It is device-agnostic: it only speaks the [control contract](../../contract/README.md), never a specific device. The device pushes to Home Assistant over plain HTTP, so there is no add-on and no MQTT. The first supported device is the Kindle Paperwhite 1 (EY21); the Kindle side is documented separately.

## Capabilities

Entities are created only for capabilities the device declares. Control and sensor entities are enabled by default, diagnostic ones are disabled by default.

| Capability | Entity | Default |
|---|---|---|
| `brightness` | number | enabled |
| `warmth` | number | enabled |
| `keep_awake` | switch | enabled |
| `refresh_screen` | button (write-only) | enabled |
| `sleep` | button (write-only) | enabled |
| `battery_level` | sensor | enabled |
| `charging` | binary_sensor | enabled |
| `frontlight_on` | binary_sensor | disabled (diagnostic) |
| `power_state` | sensor | disabled (diagnostic) |
| `cpu_usage` | sensor | disabled (diagnostic) |
| `cpu_load` | sensor | disabled (diagnostic) |
| `memory_total` | sensor | disabled (diagnostic) |
| `memory_free` | sensor | disabled (diagnostic) |
| `storage_total` | sensor | disabled (diagnostic) |
| `storage_free` | sensor | disabled (diagnostic) |
| `rootfs_used_percent` | sensor | disabled (diagnostic) |
| `clock_offset` | sensor | disabled (diagnostic) |
| `uptime` | sensor | disabled (diagnostic) |
| `battery_temperature` | sensor | disabled (diagnostic) |
| `battery_voltage` | sensor | disabled (diagnostic) |
| `battery_current` | sensor | disabled (diagnostic) |
| `wifi_signal` | sensor | disabled (diagnostic) |
| `ip_address` | sensor | disabled (diagnostic) |
| `ssid` | sensor | disabled (diagnostic) |
| `mac_address` | sensor | disabled (diagnostic) |
| `kernel_version` | sensor | disabled (diagnostic) |

No lock capability exists in v1. The reasons are device-agnostic and live in the project docs.

## Install

1. Copy `custom_components/panel_control` into your Home Assistant `custom_components` folder. The repo layout is HACS-style: `hacs.json` lives in `control/`.
2. Restart Home Assistant.
3. Settings, Devices & services, Add Integration, "Panel Control".

## Pairing

1. Enter a name (for example "Kitchen Kindle"). It becomes the device id (a slug of the name).
2. The next screen shows a URL and a 5-word passphrase. Copy them into the Kindle `config` file over USB as `url=` and `token=`.
3. Submit to create the entry.

The passphrase is typed by hand on the device, so it is forgiving: lowercase words from a 674-word list, compared ignoring case, spaces and hyphens. Five words give about 47 bits.

The Kindle cannot resolve `.local` or bare hostnames, only IP addresses, so the URL must contain an IP. The flow uses your internal URL if set, otherwise the detected LAN IP, and shows a warning when the URL is a hostname or no IP could be determined. In that case put the LAN IP of the HA machine in the config yourself.

## Entities

- Enabling an entity makes the device start reporting it, within one heartbeat (60 s).
- `ip_address`, `ssid` and `mac_address` are sensitive diagnostics: disabled by default and never logged.
- The hello `mac` is stored in the device registry even while the `mac_address` entity is disabled. A paired device that claims another device's MAC would be merged into that device.
- Enabling or disabling an entity takes effect on the device within one heartbeat (60 s) and also triggers a reload of the integration, which Home Assistant starts a few seconds after the change. A request that arrives during that reload can get a transient `404 unknown_device` or `409 hello_required`. The device handles both by backing off and re-sending hello.
- The Kindle `config` file also accepts optional `device_name` and `send_serial=1`.

## Behaviour

- Entities go unavailable after 3 missed heartbeats (about 3 minutes).
- Commands are best-effort and fire-once. Only the latest value per capability is kept, and a command expires after 5 minutes. A failed command (`ok:false` ack) is logged as a warning and not retried.
- After an HA restart, entities are restored from storage and stay unavailable until the device reconnects.

## Security

- The default URL is plain HTTP on the LAN. The passphrase is sent as a bearer token and is visible on the LAN, which is acceptable for a home network.
- An https reverse proxy works because the URL is just a string. Behind a proxy, HA's own forwarded-header settings (`use_x_forwarded_for`, trusted proxies) decide the client address that the lockout uses.
- Lockout: 10 wrong passphrases from one IP lock that IP for 5 minutes (HTTP 429).
- Options, "Regenerate passphrase": the old passphrase stops working immediately and the entry reloads. Copy the new one into the Kindle `config`.
- The device serial number is never stored.

## More

Wire protocol, endpoints and error codes: [control contract](../../contract/README.md).
