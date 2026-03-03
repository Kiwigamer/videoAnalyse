#!/bin/bash
# PiStation Diagnose-Skript
# Ausführen mit: sudo bash diagnose.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REPO_DIR/.env"

C_RED='\033[0;31m'
C_GRN='\033[0;32m'
C_YEL='\033[1;33m'
C_BLU='\033[1;34m'
C_RST='\033[0m'
C_BLD='\033[1m'

ok()   { echo -e "  ${C_GRN}[OK]${C_RST}  $*"; }
fail() { echo -e "  ${C_RED}[FAIL]${C_RST} $*"; }
warn() { echo -e "  ${C_YEL}[WARN]${C_RST} $*"; }
hdr()  { echo -e "\n${C_BLU}${C_BLD}══ $* ══${C_RST}"; }

echo -e "${C_BLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║       PiStation Diagnose-Tool                ║"
echo "║  $(date '+%Y-%m-%d %H:%M:%S')                      ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${C_RST}"

# ─── .env ────────────────────────────────────────────────
hdr ".env Konfiguration"
if [ -f "$ENV_FILE" ]; then
    ok ".env gefunden: $ENV_FILE"
    source "$ENV_FILE"
    AP_IP="${AP_IP:-10.42.0.1}"
    [ -n "$AP_SSID" ]     && ok "AP_SSID=$AP_SSID"        || fail "AP_SSID nicht gesetzt"
    [ -n "$AP_PASSWORD" ] && ok "AP_PASSWORD=*gesetzt*"    || fail "AP_PASSWORD nicht gesetzt"
    [ -n "$AP_IP" ]       && ok "AP_IP=$AP_IP"             || fail "AP_IP nicht gesetzt"
    [ -n "$MEDIA_DIR" ]   && ok "MEDIA_DIR=$MEDIA_DIR"     || fail "MEDIA_DIR nicht gesetzt"
    [ -n "$FALLBACK_WIFI_SSID" ] && warn "FALLBACK_WIFI_SSID=$FALLBACK_WIFI_SSID  (AP wird als Fallback genutzt)" \
                                || ok "FALLBACK_WIFI_SSID nicht gesetzt (reiner AP-Modus)"
else
    fail ".env nicht gefunden — bitte: cp .env.example .env"
fi

# ─── Netzwerk-Interfaces ─────────────────────────────────
hdr "Netzwerk-Interfaces"
ip link show | grep -E "^[0-9]" | while read -r line; do
    echo "  $line"
done

if ip link show wlan0 &>/dev/null; then
    ok "wlan0 vorhanden"
    WLAN_IP=$(ip addr show wlan0 | grep "inet " | awk '{print $2}')
    [ -n "$WLAN_IP" ] && ok "wlan0 IP: $WLAN_IP" || warn "wlan0 hat keine IP"
else
    fail "wlan0 nicht gefunden! Interface-Namen:"
    ip link show | grep -E "^[0-9]" | awk '{print "    " $2}'
fi

# ─── rfkill ──────────────────────────────────────────────
hdr "WLAN rfkill Status"
if rfkill list wifi 2>/dev/null | grep -q "Soft blocked: yes"; then
    fail "WLAN ist SOFT BLOCKED  →  sudo rfkill unblock wifi"
elif rfkill list wifi 2>/dev/null | grep -q "Hard blocked: yes"; then
    fail "WLAN ist HARD BLOCKED (Hardware-Schalter?)"
else
    ok "WLAN ist nicht blockiert"
fi

# ─── Pakete ──────────────────────────────────────────────
hdr "Installierte Pakete"
for pkg in hostapd dnsmasq mpv chromium python3 curl iptables dhcpcd; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        ok "$pkg installiert"
    else
        fail "$pkg FEHLT  →  sudo apt-get install -y $pkg"
    fi
done

# Python-Module
hdr "Python-Module"
for mod in flask flask_socketio eventlet; do
    if python3 -c "import $mod" 2>/dev/null; then
        VER=$(python3 -c "import $mod; print(getattr($mod, '__version__', 'ok'))" 2>/dev/null)
        ok "$mod ($VER)"
    else
        fail "$mod FEHLT  →  sudo pip3 install $mod --break-system-packages"
    fi
done

# ─── Systemd Services ────────────────────────────────────
hdr "Systemd Services"
for svc in pistation-ap pistation-server pistation-player pistation-kiosk hostapd dnsmasq; do
    LOADED=$(systemctl is-enabled "$svc" 2>/dev/null)
    ACTIVE=$(systemctl is-active  "$svc" 2>/dev/null)

    if [ "$LOADED" = "masked" ]; then
        fail "$svc ist MASKED  →  sudo systemctl unmask $svc"
    elif [ "$LOADED" = "enabled" ] && [ "$ACTIVE" = "active" ]; then
        ok "$svc  [enabled, active]"
    elif [ "$LOADED" = "enabled" ] && [ "$ACTIVE" != "active" ]; then
        fail "$svc  [enabled, aber NICHT aktiv — Status: $ACTIVE]"
    elif [ "$LOADED" = "disabled" ]; then
        warn "$svc  [disabled]"
    else
        warn "$svc  [$LOADED / $ACTIVE]"
    fi
done

# ─── hostapd Konfiguration ───────────────────────────────
hdr "hostapd Konfiguration"
if [ -f /etc/hostapd/hostapd.conf ]; then
    ok "/etc/hostapd/hostapd.conf vorhanden"
    grep -E "^(ssid|interface|channel|wpa_passphrase)" /etc/hostapd/hostapd.conf | while read -r l; do
        [[ "$l" == *"passphrase"* ]] && echo "  $l" | sed 's/=.*/=***/' || echo "  $l"
    done
else
    fail "/etc/hostapd/hostapd.conf fehlt!"
fi

if [ -f /etc/default/hostapd ]; then
    DAEMON_CONF=$(grep "DAEMON_CONF" /etc/default/hostapd | head -1)
    [ -n "$DAEMON_CONF" ] && ok "/etc/default/hostapd: $DAEMON_CONF" \
                           || fail "DAEMON_CONF nicht in /etc/default/hostapd gesetzt"
else
    fail "/etc/default/hostapd fehlt!"
fi

# ─── dnsmasq ─────────────────────────────────────────────
hdr "dnsmasq Konfiguration"
[ -f /etc/dnsmasq.conf ]  && ok "/etc/dnsmasq.conf vorhanden"  || fail "/etc/dnsmasq.conf fehlt"
[ -d /etc/dnsmasq.d ]      && ok "/etc/dnsmasq.d/ vorhanden"   || fail "/etc/dnsmasq.d/ fehlt  →  sudo mkdir -p /etc/dnsmasq.d"

# ─── PiStation Server Logs ───────────────────────────────
hdr "pistation-server letzte Logs"
journalctl -u pistation-server -n 20 --no-pager 2>/dev/null | sed 's/^/  /'

hdr "pistation-ap letzte Logs"
journalctl -u pistation-ap -n 20 --no-pager 2>/dev/null | sed 's/^/  /'

hdr "hostapd letzte Logs"
journalctl -u hostapd -n 20 --no-pager 2>/dev/null | sed 's/^/  /'

# ─── Python Server direkt testen ─────────────────────────
hdr "Python Server Test"
PY_TEST=$(python3 - <<PYEOF 2>&1
import sys, os
sys.path.insert(0, "$REPO_DIR/services")
try:
    import importlib.util as ilu
    s = ilu.spec_from_file_location("player_controller", "$REPO_DIR/services/player-controller.py")
    m = ilu.module_from_spec(s)
    s.loader.exec_module(m)
    print("player-controller.py: OK")
except Exception as e:
    print("player-controller.py: FEHLER — " + str(e))
try:
    import flask
    print("flask " + flask.__version__ + ": OK")
except Exception as e:
    print("flask: FEHLER — " + str(e))
try:
    import flask_socketio
    print("flask_socketio: OK")
except Exception as e:
    print("flask_socketio: FEHLER — " + str(e))
try:
    import eventlet
    print("eventlet " + eventlet.__version__ + ": OK")
except Exception as e:
    print("eventlet: FEHLER — " + str(e))
PYEOF
)
while IFS= read -r line; do
    [[ "$line" == *FEHLER* ]] && fail "$line" || ok "$line"
done <<< "$PY_TEST"

# ─── Port 80 / Listening ─────────────────────────────────
hdr "Port-Belegung"
ss -tlnp 2>/dev/null | grep -E ":80 |:8080 " | while read -r line; do
    echo "  $line"
done
ss -tlnp 2>/dev/null | grep -qE ":80 " && ok "Port 80 wird genutzt" || warn "Nichts hört auf Port 80"
# ─── Log-Dateien ─────────────────────────────────────────────
hdr "Log-Dateien (/var/log/pistation/)"
for lf in /var/log/pistation/install.log /var/log/pistation/ap-manager.log \
           /var/log/pistation/server.log  /var/log/pistation/kiosk.log; do
    if [ -f "$lf" ]; then
        ok "$lf  ($(wc -l < "$lf") Zeilen, letzte Änderung: $(stat -c %y "$lf" | cut -d. -f1))"
        echo "  --- letzte 10 Zeilen ---"
        tail -10 "$lf" | sed 's/^/  /'
        echo ""
    else
        warn "$lf  (noch nicht vorhanden)"
    fi
done
# ─── Zusammenfassung ─────────────────────────────────────
hdr "Zusammenfassung"
echo ""
FAILS=$(
    { [ ! -f "$ENV_FILE" ] && echo "env"; } ;
    { ! ip link show wlan0 &>/dev/null && echo "wlan0"; } ;
    { ! dpkg -l hostapd 2>/dev/null | grep -q "^ii" && echo "hostapd-pkg"; } ;
    { systemctl is-enabled hostapd 2>/dev/null | grep -q "masked" && echo "hostapd-masked"; } ;
    { ! dpkg -l iptables 2>/dev/null | grep -q "^ii" && echo "iptables"; } ;
    { ! python3 -c "import flask_socketio" 2>/dev/null && echo "flask-socketio"; } ;
    { [ ! -d /etc/dnsmasq.d ] && echo "dnsmasq.d"; }
)

if [ -z "$FAILS" ]; then
    echo -e "  ${C_GRN}${C_BLD}Keine kritischen Probleme gefunden!${C_RST}"
else
    echo -e "  ${C_RED}${C_BLD}Folgende Probleme gefunden:${C_RST}"
    for f in $FAILS; do echo "    - $f"; done
    echo ""
    echo -e "  ${C_YEL}Schnell-Fix:${C_RST}"
    echo "  sudo apt-get install -y iptables dhcpcd"
    echo "  sudo systemctl unmask hostapd && sudo systemctl enable hostapd"
    echo "  sudo mkdir -p /etc/dnsmasq.d"
    echo "  sudo pip3 install flask flask-socketio eventlet python-dotenv --break-system-packages"
    echo "  sudo bash $REPO_DIR/install.sh"
fi

echo ""
