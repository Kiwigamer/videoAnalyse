#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[1/8] Updating package index..."
apt-get update

echo "[2/8] Installing required packages..."
apt-get install -y dnsmasq hostapd lighttpd

echo "[3/8] Installing AP configuration files..."
cp "$SCRIPT_DIR/config/dnsmasq.conf" /etc/dnsmasq.conf
cp "$SCRIPT_DIR/config/hostapd.conf" /etc/hostapd/hostapd.conf
mkdir -p /etc/sysctl.d
cp "$SCRIPT_DIR/config/sysctl.conf" /etc/sysctl.d/99-videoanalyse-routed-ap.conf
sysctl --system >/dev/null

echo "DAEMON_CONF=\"/etc/hostapd/hostapd.conf\"" > /etc/default/hostapd

echo "[4/8] Installing WLAN mode manager..."
install -m 0755 "$SCRIPT_DIR/services/wlan-mode-manager.sh" /usr/local/bin/wlan-mode-manager.sh
install -m 0644 "$SCRIPT_DIR/systemd/videoanalyse-wlan-mode.service" /etc/systemd/system/videoanalyse-wlan-mode.service

echo "[5/8] Installing helper commands..."
cat > /usr/local/bin/videoanalyse-ap-once << 'EOF'
#!/bin/bash
set -euo pipefail
wlan-mode-manager.sh arm-ap-once
echo "AP mode armed for next boot only. Run: sudo reboot"
EOF
chmod +x /usr/local/bin/videoanalyse-ap-once

cat > /usr/local/bin/videoanalyse-ap-disarm << 'EOF'
#!/bin/bash
set -euo pipefail
wlan-mode-manager.sh disarm-ap
echo "AP mode disarmed. Default client Wi-Fi will be used on next boot."
EOF
chmod +x /usr/local/bin/videoanalyse-ap-disarm

cat > /usr/local/bin/videoanalyse-ap-status << 'EOF'
#!/bin/bash
set -euo pipefail
wlan-mode-manager.sh status
EOF
chmod +x /usr/local/bin/videoanalyse-ap-status

echo "[6/8] Enabling safe boot-mode service..."
systemctl daemon-reload
systemctl enable videoanalyse-wlan-mode.service

echo "[7/8] Keeping AP services disabled by default (failsafe)..."
systemctl unmask hostapd || true
systemctl disable hostapd dnsmasq || true
systemctl stop hostapd dnsmasq || true

echo "[8/8] Deploying web content and starting web server..."
cp -r "$SCRIPT_DIR/web"/* /var/www/html/
systemctl enable lighttpd
systemctl restart lighttpd

echo ""
echo "Installation complete."
echo "Default mode: client Wi-Fi (SSH-safe)."
echo "To enable AP only for next boot: sudo videoanalyse-ap-once ; sudo reboot"
echo "To check status: sudo videoanalyse-ap-status"
echo "To cancel AP request: sudo videoanalyse-ap-disarm"