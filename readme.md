# videoAnalyse hotspot setup

This repository configures a Raspberry Pi as a local Wi-Fi hotspot using the same values as your tutorial.

## What this setup does

- Creates hotspot SSID: `raspberrypi`
- Uses AP IP `192.168.4.1/24` when AP mode is enabled
- Runs DHCP via `dnsmasq` from `192.168.4.2` to `192.168.4.20`
- Routes `raspberry.com` to `192.168.4.1`
- Adds iptables NAT rules including port 80 → 3000 DNAT
- Keeps normal client Wi-Fi by default for SSH safety
- Supports one-time AP enable with automatic 15s rollback on failure

## Install

```bash
git clone https://github.com/Kiwigamer/videoAnalyse.git
cd videoAnalyse
sudo bash install.sh
sudo reboot
```

## Recovery commands (old broken hook)

Run these on the Pi if an old install still causes boot issues:

```bash
sudo systemctl disable --now videoanalyse-wlan-mode.service || true
sudo rm -f /etc/systemd/system/videoanalyse-wlan-mode.service
sudo rm -f /usr/local/bin/wlan-mode-manager.sh
sudo systemctl daemon-reload
```

Then run:

```bash
sudo bash install.sh
sudo reboot
```

## One-time AP with failsafe

Arm AP for next boot only:

```bash
sudo videoanalyse-ap-once
sudo reboot
```

Status:

```bash
sudo videoanalyse-ap-status
```

Cancel AP before reboot:

```bash
sudo videoanalyse-ap-disarm
```

Force safe client mode immediately:

```bash
sudo videoanalyse-wlan-safe
```

## After reboot

- Default boot: Pi uses normal client Wi-Fi for SSH.
- If AP was armed and starts correctly: join `raspberrypi`.
- AP failure case: script waits 15s, then auto-reverts to client mode.