#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== PiMediaStation Installer ==="

# --- 1. Pakete installieren ---
echo "[1/10] Installiere Pakete..."
apt-get update
apt-get install -y \
    mpv \
    python3-flask \
    python3-pip \
    hostapd \
    dnsmasq \
    chromium \
    xorg \
    openbox \
    unclutter \
    python3-websocket \
    python3-flask-socketio \
    python3-eventlet \
    curl \
    qrencode \
    iptables \
    dhcpcd \
    isc-dhcp-client 2>/dev/null || true

pip3 install flask flask-socketio eventlet python-dotenv --break-system-packages

# Socket.IO Client-Bibliothek herunterladen (für Offline-Betrieb)
SOCKETIO_JS="$SCRIPT_DIR/web/static/socket.io.min.js"
if [ ! -f "$SOCKETIO_JS" ]; then
    echo "  Lade socket.io.min.js herunter..."
    curl -fsSL \
        "https://cdnjs.cloudflare.com/ajax/libs/socket.io/4.7.5/socket.io.min.js" \
        -o "$SOCKETIO_JS" || {
        echo "  WARNUNG: socket.io.min.js konnte nicht heruntergeladen werden."
        echo "           Bitte manuell in web/static/ ablegen."
    }
fi

# --- 2. .env laden ---
echo "[2/10] Lade Konfiguration..."
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "FEHLER: .env nicht gefunden. Bitte erst: cp .env.example .env"
    exit 1
fi

# shellcheck disable=SC1090
source "$SCRIPT_DIR/.env"
export AP_SSID AP_PASSWORD AP_CHANNEL AP_IP AP_DHCP_RANGE_START AP_DHCP_RANGE_END
export FALLBACK_WIFI_SSID FALLBACK_WIFI_PASSWORD
export SERVER_PORT MEDIA_DIR SOCKET_PATH MPV_VOLUME

# --- 3. Verzeichnisse erstellen ---
echo "[3/10] Erstelle Verzeichnisse..."
mkdir -p "$MEDIA_DIR"
chown pi:pi "$MEDIA_DIR"
mkdir -p /var/log/pistation
chown pi:pi /var/log/pistation

# --- 4. hostapd konfigurieren ---
echo "[4/10] Konfiguriere hostapd..."
sed \
    -e "s|\${AP_SSID}|$AP_SSID|g" \
    -e "s|\${AP_PASSWORD}|$AP_PASSWORD|g" \
    -e "s|\${AP_CHANNEL}|$AP_CHANNEL|g" \
    "$SCRIPT_DIR/config/hostapd.conf.template" > /etc/hostapd/hostapd.conf

echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' > /etc/default/hostapd

# hostapd unmaskieren (auf Trixie oft masked)
systemctl unmask hostapd
systemctl enable hostapd

# --- 5. dnsmasq konfigurieren ---
echo "[5/10] Konfiguriere dnsmasq..."
if [ -f /etc/dnsmasq.conf ]; then
    cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak.$(date +%Y%m%d%H%M%S)
fi

# /etc/dnsmasq.d Verzeichnis erstellen (wird von dnsmasq erwartet)
mkdir -p /etc/dnsmasq.d

sed \
    -e "s|\${AP_IP}|$AP_IP|g" \
    -e "s|\${AP_DHCP_RANGE_START}|$AP_DHCP_RANGE_START|g" \
    -e "s|\${AP_DHCP_RANGE_END}|$AP_DHCP_RANGE_END|g" \
    "$SCRIPT_DIR/config/dnsmasq.conf.template" > /etc/dnsmasq.conf

# --- 6. dhcpcd.conf anpassen (nur im AP-Modus) ---
echo "[6/10] Konfiguriere dhcpcd..."
if [ -z "$FALLBACK_WIFI_SSID" ]; then
    if ! grep -q "# PiStation AP Config" /etc/dhcpcd.conf; then
        echo "" >> /etc/dhcpcd.conf
        echo "# PiStation AP Config" >> /etc/dhcpcd.conf
        sed \
            -e "s|\${AP_IP}|$AP_IP|g" \
            "$SCRIPT_DIR/config/dhcpcd.conf.append" >> /etc/dhcpcd.conf
    fi
else
    echo "  Fallback-WLAN konfiguriert — dhcpcd wird nicht statisch konfiguriert."
fi

# --- 7. systemd Services installieren ---
echo "[7/10] Installiere systemd Services..."
cp "$SCRIPT_DIR/systemd/pistation-ap.service"     /etc/systemd/system/
cp "$SCRIPT_DIR/systemd/pistation-server.service" /etc/systemd/system/
cp "$SCRIPT_DIR/systemd/pistation-player.service" /etc/systemd/system/
cp "$SCRIPT_DIR/systemd/pistation-kiosk.service"  /etc/systemd/system/

# Passe Pfade in Service-Dateien an
for f in /etc/systemd/system/pistation-*.service; do
    sed -i "s|/home/pi/pi-media-station|$SCRIPT_DIR|g" "$f"
done

# --- 8. systemd reload + enable ---
echo "[8/10] Aktiviere Services..."
systemctl daemon-reload
systemctl enable pistation-ap pistation-server pistation-player pistation-kiosk

# --- 9. X11 + Openbox Autostart ---
echo "[9/10] Konfiguriere X11 / Openbox..."

# Erlaube beliebigen Nutzer X11 zu starten
cat > /etc/X11/Xwrapper.config << 'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

# Openbox Autostart
OPENBOX_DIR=/home/pi/.config/openbox
mkdir -p "$OPENBOX_DIR"
cat > "$OPENBOX_DIR/autostart" << AUTOSTART
# PiStation Kiosk
/home/pi/pi-media-station/services/dashboard-start.sh &
AUTOSTART
# Korrekten Pfad einsetzen
sed -i "s|/home/pi/pi-media-station|$SCRIPT_DIR|g" "$OPENBOX_DIR/autostart"
chown -R pi:pi /home/pi/.config

# Skripte ausführbar machen
chmod +x "$SCRIPT_DIR/services/ap-manager.sh"
chmod +x "$SCRIPT_DIR/services/dashboard-start.sh"
chmod +x "$SCRIPT_DIR/services/media-server.py"
chmod +x "$SCRIPT_DIR/services/player-controller.py"

# --- 10. Fertig ---
echo ""
echo "=============================================="
echo "[10/10] Installation abgeschlossen."
echo "Bitte neu starten: sudo reboot"
echo "=============================================="
