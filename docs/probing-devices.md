# Probing a device

Probe the real hardware before writing a device layer (`devices/<device-id>/`). Never copy lipc/sysfs names from the internet into code without confirming them on the device.

## Safety rules (real hardware)

1. Start read-only: only `lipc-probe`, `lipc-get-prop`, `cat`, `ls`, `find`, `df`. No writes until the capability table says what is safe.
2. Never write to `/`, `/etc`, `/var/local/*.db`, `/dev/mmcblk*` or system sysfs nodes, and never change the firmware or `appreg.db` during probing. Never run `reboot`, framework stop/start or remount commands before USB-cable recovery is confirmed.
3. Check free space before writing files. Keep files on the user partition (`/mnt/us`), not the root fs.
4. Do write tests one at a time. Record the current value first, change in small steps inside the reported range, restore the value afterwards.
5. Save probe output on your computer by redirecting the SSH output, not on the device.
6. Redact serial, board id, MAC and IP addresses before committing probe output.
7. Probe commands must work on the device's own tools (the EY21 has BusyBox 1.17.1, so no `grep -E`).

## Generic workflow (any device)

1. Set up a recovery route that works without Wi-Fi, and record it in `devices/<device-id>/README.md`.
2. Get a shell on the device.
3. Run the device's probe commands and save the output to `devices/<device-id>/probe-output.txt`. Commit it.
4. Add one row per contract capability to `devices/<device-id>/README.md`: how to read it, how to write it, the native range, the mapping to the contract's normalized value, and notes. Mark it unsupported if nothing works. Don't fake it.
5. Probe power-impact where it matters (see the lock steps below) and record the numbers.
6. Only then implement the device layer.

## Kindle Paperwhite 1 / 5th gen (EY21, MX50 Yoshime)

Already probed, see `devices/kindle-ey21/README.md`. Commands below are for re-probing and are BusyBox 1.17-safe.

Prerequisite: jailbroken, KUAL installed.

### Recovery and shell

1. Install USBNetwork (it bundles SSH). Check it supports your firmware first (Kindle Modding wiki, MobileRead). If it doesn't, document your alternative recovery route.
2. Enable it from KUAL and confirm `ssh root@<ip>` works over the USB cable, before any lock or power experiment.
3. Use the cable for lock experiments. Use Wi-Fi SSH for everyday probing.
4. Run probes from the normal Kindle UI with the dashboard stopped (`run.sh` stops the GUI).
5. If the device hangs, hold the power button for 40 seconds to hard reset.

### Probe commands

1. Run this from your computer, so the output stays off the device (`ssh kindle-pw1 'sh -s' < probe.sh > probe-output.txt`), or paste the block into an SSH session without the final redirect:

```sh
{
echo "## version";      cat /etc/version.txt; uname -a
echo "## lipc services"; lipc-probe -l
echo "## powerd";        lipc-probe -v com.lab126.powerd
echo "## powerd values"; for p in flIntensity flMaxIntensity currentAmberLevel battLevel isCharging preventScreenSaver state; do echo "$p=$(lipc-get-prop com.lab126.powerd $p 2>&1)"; done
echo "## brightness nodes"; find /sys -name brightness 2>/dev/null
echo "## battery nodes"; find /sys -name '*batt*' 2>/dev/null
echo "## system";        cat /proc/loadavg; head -5 /proc/meminfo; df -k /mnt/us
echo "## tools";         which curl wget nc busybox
} 2>&1
```

2. Save the output as `devices/kindle-ey21/probe-output.txt` and redact identifiers first.
3. Check the lipc names in the output against `devices/<device-id>/README.md` and update the table if they differ.

### Lock probe (not in v1, see `docs/future/control-v2.md`)

Kept for when `lock` returns. The EY21 result is in `devices/kindle-ey21/README.md`.

Preference order: (a) the real system lock with an optional custom screensaver, as it uses the least power; (b) a static image with the backlight off. Touch stays enabled unless blocking it measurably saves power. Drop `lock` from v1 if neither works.

1. Find candidates that trigger the screensaver, lock or suspend in the `powerd` listing and in `lipc-probe -l`. Treat them as unverified.
2. With `preventScreenSaver` at 0, run each candidate and watch the screen. Record whether it locks, shows the screensaver, and wakes on the power button.
3. Measure the battery current (EY21: `/sys/devices/system/yoshi_battery/yoshi_battery0/battery_current`; other devices: `current_now`) every few seconds for 2 minutes after the screen settles. Do it for the system lock, the static image, and touch blocked vs. enabled, with Wi-Fi in the same state each time. Record the numbers in `devices/kindle-ey21/README.md`.
4. Choose the system lock if it works. Otherwise choose the static image. Block touch only if the measured saving is real.
5. Check whether Wi-Fi and the agent stay reachable (or can be woken) while the system lock is active. If not, document that `lock` commands from HA are delayed.
