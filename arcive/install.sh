#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Logging: alles nach Datei UND Terminal ---
LOG_DIR="/var/log/pistation"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/install.log"

# Alle Ausgaben (stdout + stderr) in Log schreiben
exec > >(tee -a "$LOG_FILE") 2>&1

# Bei Fehler: Zeile und Exit-Code ins Log schreiben
trap 'EC=$?; echo ""; echo "[FEHLER] install.sh abgebrochen in Zeile $LINENO (Exit-Code $EC)" ; echo "[FEHLER] Zeitstempel: $(date)" ; echo "[FEHLER] Logdatei: $LOG_FILE"' ERR

echo ""
echo "============================================"
echo "=== PiMediaStation Installer ==="
echo "=== Start: $(date) ==="
echo "=== Logdatei: $LOG_FILE ==="
echo "============================================"
echo ""

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
    dhcpcd

# isc-dhcp-client: optional, nicht auf Trixie verfügbar
apt-get install -y isc-dhcp-client 2>/dev/null || \
    echo "  INFO: isc-dhcp-client nicht verfügbar (auf Trixie normal) — dhcpcd wird genutzt."

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

# QR-Code Bibliothek herunterladen (für Offline-Betrieb, statt CDN)
QRCODE_JS="$SCRIPT_DIR/web/static/qrcode.min.js"
if [ ! -f "$QRCODE_JS" ]; then
    echo "  Lade qrcode.min.js herunter..."
    curl -fsSL \
        "https://cdn.jsdelivr.net/npm/qrcodejs@1.0.0/qrcode.min.js" \
        -o "$QRCODE_JS" || {
        echo "  WARNUNG: qrcode.min.js konnte nicht heruntergeladen werden."
        echo "           Dashboard-QR-Code funktioniert nicht offline."
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
export AP_SSID AP_PASSWORD AP_CHANNEL AP_COUNTRY AP_IP AP_DHCP_RANGE_START AP_DHCP_RANGE_END
export FALLBACK_WIFI_SSID FALLBACK_WIFI_PASSWORD
export SERVER_PORT MEDIA_DIR SOCKET_PATH MPV_VOLUME

# Standardwert für AP_COUNTRY falls nicht in .env gesetzt
: "${AP_COUNTRY:=DE}"

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
    -e "s|\${AP_COUNTRY}|$AP_COUNTRY|g" \
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

# --- 6. dhcpcd.conf anpassen ---
echo "[6/10] Konfiguriere dhcpcd..."
# 'nohook wpa_supplicant' IMMER eintragen — verhindert, dass dhcpcd
# automatisch wpa_supplicant startet und das Interface von hostapd klaut.
if ! grep -q "# PiStation AP Config" /etc/dhcpcd.conf; then
    echo "" >> /etc/dhcpcd.conf
    echo "# PiStation AP Config" >> /etc/dhcpcd.conf
    if [ -z "$FALLBACK_WIFI_SSID" ]; then
        # Kein Fallback: statische IP + kein wpa_supplicant-Hook
        sed \
            -e "s|\${AP_IP}|$AP_IP|g" \
            "$SCRIPT_DIR/config/dhcpcd.conf.append" >> /etc/dhcpcd.conf
    else
        # Mit Fallback: trotzdem wpa_supplicant-Hook deaktivieren;
        # ap-manager.sh konfiguriert das Interface dynamisch.
        echo "interface wlan0" >> /etc/dhcpcd.conf
        echo "nohook wpa_supplicant" >> /etc/dhcpcd.conf
        echo "  Fallback-WLAN konfiguriert — nur nohook wpa_supplicant gesetzt."
    fi
fi

# wpa_supplicant-Dienste deaktivieren — ap-manager.sh übernimmt alle WLAN-Verwaltung.
# wpa_supplicant@wlan0 ist der Instanz-Service auf modernem Pi OS (Bookworm).
systemctl disable wpa_supplicant        2>/dev/null || true
systemctl disable wpa_supplicant@wlan0  2>/dev/null || true
systemctl mask    wpa_supplicant@wlan0  2>/dev/null || true
echo "  wpa_supplicant@wlan0 deaktiviert und maskiert"

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

# pistation-player NICHT enablen: media-server.py startet mpv selbst via IPC.
# Beide gleichzeitig würden auf demselben Socket kollidieren.
systemctl disable pistation-player 2>/dev/null || true
systemctl enable pistation-ap pistation-server pistation-kiosk

# dnsmasq beim Boot NICHT starten — ap-manager.sh startet/stoppt es bei Bedarf.
# So werden keine Ports blockiert wenn nur Fallback-WLAN aktiv ist.
systemctl disable dnsmasq 2>/dev/null || true
echo "  INFO: dnsmasq bleibt disabled (ap-manager startet es bei Bedarf)"

# --- 9. X11 + Openbox Autostart + Autologin ---
echo "[9/10] Konfiguriere X11 / Openbox / Autologin..."

# Erlaube beliebigen Nutzer X11 zu starten
cat > /etc/X11/Xwrapper.config << 'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

# --- Autologin auf tty1 ---
# Pi OS Lite hat keinen Display-Manager. Diese Konfiguration sorgt dafür,
# dass Nutzer 'pi' automatisch auf tty1 eingeloggt wird.
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin pi --noclear %I $TERM
EOF
echo "  Autologin für pi auf tty1 konfiguriert"

# --- .bash_profile: startx automatisch auf tty1 ---
# Wenn keine DISPLAY-Variable gesetzt ist und Login auf tty1 → startx
if [ ! -f /home/pi/.bash_profile ] || ! grep -q 'PiStation' /home/pi/.bash_profile; then
    cat > /home/pi/.bash_profile << 'BASHEOF'
# PiStation: X11 auf tty1 automatisch starten
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx 2>>/var/log/pistation/startx.log
fi
BASHEOF
    chown pi:pi /home/pi/.bash_profile
    echo "  .bash_profile erstellt (startet X auf tty1)"
else
    echo "  .bash_profile bereits vorhanden — unverändert"
fi

# --- .xinitrc: openbox-session starten ---
cat > /home/pi/.xinitrc << 'XINITEOF'
exec openbox-session
XINITEOF
chown pi:pi /home/pi/.xinitrc
echo "  .xinitrc erstellt (startet openbox-session)"

# --- Openbox Autostart ---
OPENBOX_DIR=/home/pi/.config/openbox
mkdir -p "$OPENBOX_DIR"
cat > "$OPENBOX_DIR/autostart" << AUTOSTART
# PiStation Kiosk — startet Dashboard in Chromium
/home/pi/pi-media-station/services/dashboard-start.sh &
AUTOSTART
# Korrekten Pfad einsetzen
sed -i "s|/home/pi/pi-media-station|$SCRIPT_DIR|g" "$OPENBOX_DIR/autostart"
chown -R pi:pi /home/pi/.config
echo "  Openbox Autostart konfiguriert: $OPENBOX_DIR/autostart"

# Skripte ausführbar machen
chmod +x "$SCRIPT_DIR/services/ap-manager.sh"
chmod +x "$SCRIPT_DIR/services/dashboard-start.sh"
chmod +x "$SCRIPT_DIR/services/media-server.py"
chmod +x "$SCRIPT_DIR/services/player-controller.py"

# --- 10. Fertig ---
echo ""
echo "=============================================="
echo "[10/10] Installation abgeschlossen: $(date)"
echo "Logdatei gespeichert: $LOG_FILE"
echo "=============================================="
echo ""
echo "Bitte jetzt neu starten:  sudo reboot"
echo ""
