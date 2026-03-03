#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${EUID}" -ne 0 ]; then
	echo "Run with sudo: sudo bash install.sh"
	exit 1
fi

echo "[1/12] Update package index..."
apt-get update

echo "[2/12] Install required packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq hostapd iptables-persistent nodejs npm

echo "[3/12] Stop hostapd and dnsmasq until configured..."
systemctl stop dnsmasq 2>/dev/null || true
systemctl stop hostapd 2>/dev/null || true

echo "[4/12] Remove old custom boot hooks/services..."
systemctl disable --now videoanalyse-wlan-failsafe.service 2>/dev/null || true
systemctl disable --now videoanalyse-wlan-mode.service 2>/dev/null || true
rm -f /etc/systemd/system/videoanalyse-wlan-failsafe.service
rm -f /etc/systemd/system/videoanalyse-wlan-mode.service
rm -f /usr/local/bin/wlan-failsafe-manager.sh
rm -f /usr/local/bin/wlan-mode-manager.sh
rm -f /usr/local/bin/videoanalyse-ap-once
rm -f /usr/local/bin/videoanalyse-ap-disarm
rm -f /usr/local/bin/videoanalyse-wlan-safe
rm -f /usr/local/bin/videoanalyse-ap-status
systemctl daemon-reload

echo "[5/12] Configure static IP on wlan0 in /etc/dhcpcd.conf..."
if grep -q "# videoAnalyse captive portal start" /etc/dhcpcd.conf; then
	sed -i '/# videoAnalyse captive portal start/,/# videoAnalyse captive portal end/d' /etc/dhcpcd.conf
fi
cat >> /etc/dhcpcd.conf << 'EOF'
# videoAnalyse captive portal start
interface wlan0
		static ip_address=192.168.4.1/24
		nohook wpa_supplicant
# videoAnalyse captive portal end
EOF
service dhcpcd restart

echo "[6/12] Configure dnsmasq..."
if [ -f /etc/dnsmasq.conf ] && [ ! -f /etc/dnsmasq.conf.orig ]; then
	mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig
fi
cat > /etc/dnsmasq.conf << 'EOF'
interface=wlan0
dhcp-range=192.168.4.2,192.168.4.255,255.255.255.0,15m
address=/#/192.168.4.1
EOF
systemctl reload dnsmasq 2>/dev/null || true

echo "[7/12] Configure hostapd..."
cp "$SCRIPT_DIR/config/hostapd.conf" /etc/hostapd/hostapd.conf
if grep -q '^#\?DAEMON_CONF=' /etc/default/hostapd; then
	sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
else
	echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
fi

echo "[8/12] Enable and start hostapd + dnsmasq..."
systemctl unmask hostapd
systemctl enable hostapd
systemctl start hostapd
systemctl enable dnsmasq
systemctl start dnsmasq

echo "[9/12] Enable IP forwarding and apply iptables rules..."
if grep -q '^#\?net.ipv4.ip_forward=' /etc/sysctl.conf; then
	sed -i 's/^#\?net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
	echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
sysctl -p
iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || true
iptables -t nat -D PREROUTING -d 192.168.4.1 -p tcp --dport 80 -j DNAT --to-destination 192.168.4.1:3000 2>/dev/null || true
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -t nat -I PREROUTING -d 192.168.4.1 -p tcp --dport 80 -j DNAT --to-destination 192.168.4.1:3000
sh -c "iptables-save > /etc/iptables.ipv4.nat"

echo "[10/12] Ensure rc.local restores iptables at boot..."
if [ ! -f /etc/rc.local ]; then
	cat > /etc/rc.local << 'EOF'
#!/bin/sh -e
iptables-restore < /etc/iptables.ipv4.nat
exit 0
EOF
else
	if ! grep -q "iptables-restore < /etc/iptables.ipv4.nat" /etc/rc.local; then
		sed -i '/^exit 0/i iptables-restore < /etc/iptables.ipv4.nat' /etc/rc.local
	fi
fi
chmod +x /etc/rc.local

echo "[11/12] Install Node.js captive portal app..."
mkdir -p /home/pi/Node/PiWiFi
cd /home/pi/Node/PiWiFi
if [ ! -f package.json ]; then
	npm init -y
fi
npm install express
cat > /home/pi/Node/PiWiFi/app.js << 'EOF'
const express = require('express');
const app = express();
const port = 3000;

var hostName = 'pi.wifi';

app.use((req, res, next) => {
		if (req.get('host') != hostName) {
				return res.redirect(`http://${hostName}`);
		}
		next();
})

app.get('/', (req, res, next) => {
		res.send('Pi WiFi - Captive Portal');
})

app.listen(port, () => {
		console.log(`Server listening on port ${port}`)
})
EOF

echo "[12/12] Install and enable piwifi.service..."
cat > /etc/systemd/system/piwifi.service << 'EOF'
[Unit]
Description=Pi WiFi Hotspot Service
After=network.target

[Service]
WorkingDirectory=/home/pi/Node/PiWiFi
ExecStart=/usr/bin/nodejs /home/pi/Node/PiWiFi/app.js
Restart=on-failure
User=root
Environment=PORT=3000

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable piwifi.service
systemctl start piwifi.service

echo "[12.1/12] Install AP shortcut commands (apON / apOF)..."
cat > /usr/local/bin/apON << 'EOF'
#!/bin/bash
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
	echo "Use: sudo apON"
	exit 1
fi

if ! grep -q "# videoAnalyse captive portal start" /etc/dhcpcd.conf; then
cat >> /etc/dhcpcd.conf << 'EOD'
# videoAnalyse captive portal start
interface wlan0
		static ip_address=192.168.4.1/24
		nohook wpa_supplicant
# videoAnalyse captive portal end
EOD
fi

systemctl unmask hostapd 2>/dev/null || true
systemctl enable hostapd dnsmasq piwifi.service
systemctl restart dhcpcd
systemctl restart hostapd
systemctl restart dnsmasq
systemctl restart piwifi.service

echo "AP ON: hotspot active (SSID from /etc/hostapd/hostapd.conf)"
EOF
chmod +x /usr/local/bin/apON

cat > /usr/local/bin/apOF << 'EOF'
#!/bin/bash
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
	echo "Use: sudo apOF"
	exit 1
fi

if grep -q "# videoAnalyse captive portal start" /etc/dhcpcd.conf; then
	sed -i '/# videoAnalyse captive portal start/,/# videoAnalyse captive portal end/d' /etc/dhcpcd.conf
fi

systemctl stop piwifi.service 2>/dev/null || true
systemctl stop hostapd 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true

systemctl disable hostapd dnsmasq piwifi.service 2>/dev/null || true
ip addr flush dev wlan0 2>/dev/null || true
systemctl restart dhcpcd 2>/dev/null || true
systemctl restart wpa_supplicant 2>/dev/null || true
systemctl restart wpa_supplicant@wlan0 2>/dev/null || true

echo "AP OFF: default client WLAN restored"
EOF
chmod +x /usr/local/bin/apOF

echo ""
echo "Installation complete."
echo "Shortcuts: sudo apON | sudo apOF"
echo "Reboot now with: sudo reboot"