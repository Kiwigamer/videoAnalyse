#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
ENV_FILE="$SCRIPT_DIR/.env"
LOG_DIR="/var/log/pistation"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/ap-manager.log"

# Stderr ebenfalls in Log umleiten
exec 2> >(while IFS= read -r line; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STDERR] $line" | tee -a "$LOG_FILE"
done)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Bei unkontrolliertem Exit immer loggen
trap 'EC=$?; [ $EC -ne 0 ] && log "[FEHLER] ap-manager.sh beendet mit Exit-Code $EC in Zeile $LINENO"' EXIT

log "--- ap-manager.sh gestartet (PID $$) ---"
log "Repo: $SCRIPT_DIR"

# .env laden
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
else
    log "FEHLER: .env nicht gefunden unter $ENV_FILE"
    exit 1
fi

start_ap() {
    log "Starte Access Point..."

    # --- Vorherige Prozesse aufräumen -----------------------------------------
    log "Stoppe konkurrierende Prozesse (wpa_supplicant, dhcpcd, NetworkManager)..."
    systemctl stop wpa_supplicant    2>/dev/null || true
    systemctl stop NetworkManager   2>/dev/null || true
    # dhcpcd komplett stoppen – sonst re-added es die DHCP-IP nach ip addr flush!
    systemctl stop dhcpcd           2>/dev/null || true
    pkill -f "dhclient.*wlan0"      2>/dev/null || true
    pkill -f "dhcpcd.*wlan0"        2>/dev/null || true
    sleep 1

    # --- Regulatory Domain prüfen --------------------------------------------
    log "Regulatory Domain: $(iw reg get 2>&1 | head -3 | tr '\n' ' ')"
    if iw reg get 2>&1 | grep -q "country 00"; then
        log "WARNUNG: Regulatory Domain ist 'world' (00) — setze auf DE"
        iw reg set DE 2>/dev/null || true
    fi

    # --- Interface konfigurieren ---------------------------------------------
    log "Konfiguriere wlan0..."
    ip link set wlan0 down
    ip addr flush dev wlan0
    log "  IPs nach flush: $(ip addr show wlan0 | grep 'inet' | tr '\n' '|')"
    ip addr add "${AP_IP}/24" dev wlan0
    ip link set wlan0 up
    sleep 1
    log "  wlan0 nach Konfiguration: $(ip addr show wlan0 | grep 'inet' | tr '\n' '|')"
    log "  wlan0 Link-Status: $(ip link show wlan0 | head -1)"

    # --- hostapd konfigurieren & starten -------------------------------------
    log "Starte hostapd (SSID=${AP_SSID}, Kanal=${AP_CHANNEL:-6})..."
    systemctl stop  hostapd 2>/dev/null || true
    sleep 1
    systemctl start hostapd
    sleep 3

    if ! systemctl is-active --quiet hostapd; then
        log "FEHLER: hostapd konnte nicht gestartet werden!"
        log "  hostapd journal:"
        journalctl -u hostapd -n 30 --no-pager 2>&1 | while IFS= read -r line; do
            log "    [hostapd] $line"
        done
        log "  hostapd.conf Inhalt (ohne Passwort):"
        grep -v "passphrase\|password\|psk" /etc/hostapd/hostapd.conf 2>/dev/null | \
            while IFS= read -r line; do log "    $line"; done
        start_fallback
        return
    fi
    log "  hostapd aktiv — AP sendet auf Kanal ${AP_CHANNEL:-6}"

    # --- iw info / Kanal-Check -----------------------------------------------
    log "  iw dev wlan0 info:"
    iw dev wlan0 info 2>&1 | while IFS= read -r line; do log "    $line"; done

    # --- dnsmasq starten (DHCP für AP-Clients) --------------------------------
    log "Starte dnsmasq (DHCP ${AP_DHCP_RANGE_START}–${AP_DHCP_RANGE_END})..."
    systemctl stop  dnsmasq 2>/dev/null || true
    sleep 1
    systemctl start dnsmasq
    sleep 2

    if ! systemctl is-active --quiet dnsmasq; then
        log "FEHLER: dnsmasq konnte nicht gestartet werden — Clients bekommen keine IP!"
        log "  dnsmasq journal:"
        journalctl -u dnsmasq -n 30 --no-pager 2>&1 | while IFS= read -r line; do
            log "    [dnsmasq] $line"
        done
    else
        log "  dnsmasq aktiv — DHCP-Server läuft"
    fi

    # --- IP-Forwarding & iptables NAT ----------------------------------------
    log "Aktiviere IP-Forwarding und Captive-Portal NAT..."
    echo 1 > /proc/sys/net/ipv4/ip_forward

    if command -v iptables &>/dev/null; then
        iptables -t nat -F PREROUTING 2>/dev/null || true
        iptables -t nat -A PREROUTING -i wlan0 -p tcp --dport 80 -j DNAT \
            --to "${AP_IP}:${SERVER_PORT:-80}" || log "WARNUNG: iptables NAT fehlgeschlagen"
        log "  iptables NAT Regel gesetzt (Port 80 → ${AP_IP}:${SERVER_PORT:-80})"
    else
        log "WARNUNG: iptables nicht gefunden — Captive Portal NAT übersprungen"
    fi

    # --- Abschlussstatus ------------------------------------------------------
    log "=== AP-Status Zusammenfassung ==="
    log "  AP-SSID   : ${AP_SSID}"
    log "  AP-IP     : ${AP_IP}"
    log "  Kanal     : $(iw dev wlan0 info 2>/dev/null | grep channel | awk '{print $2, $3, $4}')"
    log "  wlan0-IPs : $(ip addr show wlan0 | grep 'inet' | awk '{print $2}' | tr '\n' ' ')"
    log "  hostapd   : $(systemctl is-active hostapd)"
    log "  dnsmasq   : $(systemctl is-active dnsmasq)"
    log "Access Point '${AP_SSID}' erfolgreich gestartet auf ${AP_IP}"
    exit 0
}

start_fallback() {
    log "Versuche Fallback-WLAN..."

    if [ -z "$FALLBACK_WIFI_SSID" ]; then
        log "Kein Fallback-WLAN konfiguriert (FALLBACK_WIFI_SSID ist leer)."
        exit 1
    fi

    log "Wechsle zu WLAN: $FALLBACK_WIFI_SSID"

    # AP-Dienste stoppen
    systemctl stop hostapd 2>/dev/null || true
    systemctl stop dnsmasq 2>/dev/null || true

    # Interface zurücksetzen
    ip link set wlan0 down
    ip addr flush dev wlan0
    ip link set wlan0 up

    # wpa_supplicant Config schreiben
    wpa_passphrase "$FALLBACK_WIFI_SSID" "$FALLBACK_WIFI_PASSWORD" > /tmp/wpa_fallback.conf

    # wpa_supplicant starten
    log "Starte wpa_supplicant für '$FALLBACK_WIFI_SSID'..."
    wpa_supplicant -B -i wlan0 -c /tmp/wpa_fallback.conf
    sleep 3

    # DHCP-Adresse holen — dhcpcd im Vordergrund (nicht als Hintergrundprozess, damit wlan0
    # nicht nach Beendigung dieses Skripts unkontrolliert DHCP betreibt)
    if command -v dhcpcd &>/dev/null; then
        log "Hole DHCP-Adresse via dhcpcd..."
        # -w wartet bis IP zugewiesen (max 30s intern)
        dhcpcd -w --timeout 30 wlan0 &
        DHCP_PID=$!
        # Wir warten selbst max 30s und prüfen ob IP da ist
        for i in $(seq 1 30); do
            if ip addr show wlan0 | grep -q "inet "; then
                IP=$(ip addr show wlan0 | grep "inet " | awk '{print $2}' | cut -d/ -f1)
                log "Fallback-WLAN verbunden. IP: $IP (dhcpcd PID=$DHCP_PID läuft weiter)"
                exit 0
            fi
            sleep 1
        done
    elif command -v dhclient &>/dev/null; then
        log "Hole DHCP-Adresse via dhclient..."
        dhclient wlan0 &
        for i in $(seq 1 30); do
            if ip addr show wlan0 | grep -q "inet "; then
                IP=$(ip addr show wlan0 | grep "inet " | awk '{print $2}' | cut -d/ -f1)
                log "Fallback-WLAN verbunden. IP: $IP"
                exit 0
            fi
            sleep 1
        done
    else
        log "WARNUNG: Kein DHCP-Client gefunden (dhcpcd/dhclient). IP kommt ggf. von wpa_supplicant."
        for i in $(seq 1 30); do
            if ip addr show wlan0 | grep -q "inet "; then
                IP=$(ip addr show wlan0 | grep "inet " | awk '{print $2}' | cut -d/ -f1)
                log "Fallback-WLAN verbunden (kein DHCP-Client). IP: $IP"
                exit 0
            fi
            sleep 1
        done
    fi

    log "Fallback-WLAN: Timeout beim Warten auf IP-Adresse."
    log "  wpa_supplicant Status: $(wpa_cli -i wlan0 status 2>&1 | head -5 | tr '\n' '|')"
    exit 2
}

# Hauptprogramm
start_ap
