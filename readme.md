# Raspberry Pi Wifi Hotspot with Captive Portal

This repository configures a Raspberry Pi as an open WiFi hotspot with a captive portal, following the requested flow 1:1.

## Install

```bash
git clone https://github.com/Kiwigamer/videoAnalyse.git
cd videoAnalyse
sudo bash install.sh
sudo reboot
```

## Result

- SSID: `Pi WiFi`
- AP IP: `192.168.4.1`
- DHCP: `192.168.4.2 - 192.168.4.255`
- DNS redirect: all domains -> `192.168.4.1`
- HTTP redirect: `192.168.4.1:80` -> `192.168.4.1:3000`
- Captive portal service: `piwifi.service`

## Check after reboot

```bash
sudo systemctl status hostapd dnsmasq piwifi --no-pager
```

```bash
ssh pi@192.168.4.1
```