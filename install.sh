#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${EUID}" -ne 0 ]; then
	echo "Run with sudo: sudo bash install.sh"
	exit 1
fi

echo "[1/6] Installing dependencies..."
apt-get update
apt-get install -y network-manager mpv python3-flask python3-pip xorg openbox unclutter python3-websocket python3-python-socketio python3-eventlet
# chromium-browser on older Pi OS, chromium on Bookworm
apt-get install -y chromium-browser 2>/dev/null || apt-get install -y chromium
pip3 install flask flask-socketio eventlet --break-system-packages

echo "[2/6] Preparing config and shortcuts..."
mkdir -p /home/pi/videos
cp "$SCRIPT_DIR/.env" /etc/pistation.env

cp "$SCRIPT_DIR/bin/apON" /usr/local/bin/apON
cp "$SCRIPT_DIR/bin/apOFF" /usr/local/bin/apOFF
chmod +x /usr/local/bin/apON /usr/local/bin/apOFF

# Make apON use system-wide config regardless of install directory
sed -i 's|^source .*\.env$|source /etc/pistation.env|' /usr/local/bin/apON

echo "[3/6] Installing systemd services..."
cp "$SCRIPT_DIR/systemd"/*.service /etc/systemd/system/

echo "[4/6] Rewriting service paths to this install location..."
for svc in /etc/systemd/system/pistation-server.service /etc/systemd/system/pistation-player.service /etc/systemd/system/pistation-kiosk.service; do
	sed -i "s|/home/pi/pi-media-station|$SCRIPT_DIR|g" "$svc"
	sed -i "s|EnvironmentFile=.*|EnvironmentFile=/etc/pistation.env|g" "$svc"
done

chmod +x "$SCRIPT_DIR/dashboard-start.sh" "$SCRIPT_DIR/services/media-server.py" "$SCRIPT_DIR/services/player-controller.py"

echo "[5/6] Enabling and starting services now..."
systemctl daemon-reload
systemctl reset-failed || true
systemctl enable --now pistation-server pistation-player
systemctl enable pistation-kiosk

if systemctl is-active --quiet graphical.target || [ -n "${DISPLAY:-}" ]; then
	systemctl restart pistation-kiosk || true
fi

echo "[6/6] Current status:"
systemctl --no-pager --full status pistation-server pistation-player pistation-kiosk || true
echo "Install complete. Server and player are started immediately."
