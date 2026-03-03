#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[1/9] Updating package index..."
apt-get update

echo "[2/9] Installing required packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y hostapd dnsmasq iptables-persistent lighttpd

echo "[3/9] Installing AP configuration files..."
cp "$SCRIPT_DIR/config/dnsmasq.conf" /etc/dnsmasq.conf
cp "$SCRIPT_DIR/config/hostapd.conf" /etc/hostapd/hostapd.conf
echo "DAEMON_CONF=\"/etc/hostapd/hostapd.conf\"" > /etc/default/hostapd

echo "[4/9] Installing one-time AP failsafe manager..."
install -m 0755 "$SCRIPT_DIR/services/wlan-failsafe-manager.sh" /usr/local/bin/wlan-failsafe-manager.sh
install -m 0644 "$SCRIPT_DIR/systemd/videoanalyse-wlan-failsafe.service" /etc/systemd/system/videoanalyse-wlan-failsafe.service

echo "[5/9] Cleaning up legacy boot hook (if present)..."
systemctl disable --now videoanalyse-wlan-mode.service 2>/dev/null || true
rm -f /etc/systemd/system/videoanalyse-wlan-mode.service
rm -f /usr/local/bin/wlan-mode-manager.sh

echo "[6/9] Applying iptables routing rules from tutorial..."
iptables -t nat -D PREROUTING -p tcp --dport 80 -j DNAT --to-destination 192.168.4.1:3000 2>/dev/null || true
iptables -t nat -D POSTROUTING -j MASQUERADE 2>/dev/null || true
iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination 192.168.4.1:3000
iptables -t nat -A POSTROUTING -j MASQUERADE
sh -c "iptables-save > /etc/iptables/rules.v4"

echo "[7/9] Installing helper commands..."
cat > /usr/local/bin/videoanalyse-ap-once << 'EOF'
#!/bin/bash
set -euo pipefail
wlan-failsafe-manager.sh arm-ap-once
echo "AP mode armed for next boot only. Reboot to test AP."
EOF
chmod +x /usr/local/bin/videoanalyse-ap-once

cat > /usr/local/bin/videoanalyse-ap-disarm << 'EOF'
#!/bin/bash
set -euo pipefail
wlan-failsafe-manager.sh disarm-ap
echo "AP request removed."
EOF
chmod +x /usr/local/bin/videoanalyse-ap-disarm

cat > /usr/local/bin/videoanalyse-wlan-safe << 'EOF'
#!/bin/bash
set -euo pipefail
wlan-failsafe-manager.sh force-client
echo "Client Wi-Fi restored."
EOF
chmod +x /usr/local/bin/videoanalyse-wlan-safe

cat > /usr/local/bin/videoanalyse-ap-status << 'EOF'
#!/bin/bash
set -euo pipefail
wlan-failsafe-manager.sh status
EOF
chmod +x /usr/local/bin/videoanalyse-ap-status

echo "[8/9] Enabling services and setting safe default mode..."
systemctl daemon-reload
systemctl unmask hostapd 2>/dev/null || true
systemctl enable videoanalyse-wlan-failsafe.service
/usr/local/bin/wlan-failsafe-manager.sh force-client || true

echo "[9/9] Deploying web content and starting web server..."
cp -r "$SCRIPT_DIR/web"/* /var/www/html/
systemctl enable lighttpd
systemctl restart lighttpd

echo ""
echo "Installation complete."
echo "Default boot mode: client Wi-Fi (SSH-safe)."
echo "One-time AP test: sudo videoanalyse-ap-once ; sudo reboot"
echo "Failsafe: AP startup is checked for 15 seconds, then auto-reverts to client mode on error."
echo "Manual recovery: sudo videoanalyse-wlan-safe"