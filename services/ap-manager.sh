#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
ENV_FILE="$SCRIPT_DIR/.env"
LOG_FILE="/var/log/pistation/ap-manager.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

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

    # wpa_supplicant stoppen damit wlan0 frei ist
    systemctl stop wpa_supplicant 2>/dev/null || true

    # Interface konfigurieren
    ip link set wlan0 down
    ip addr flush dev wlan0
    ip addr add "${AP_IP}/24" dev wlan0
    ip link set wlan0 up

    # hostapd und dnsmasq starten
    systemctl start hostapd
    sleep 2
    systemctl start dnsmasq

    # IP-Forwarding aktivieren
    echo 1 > /proc/sys/net/ipv4/ip_forward

    # Alle HTTP-Anfragen auf den lokalen Server umleiten (captive portal)
    iptables -t nat -F PREROUTING 2>/dev/null || true
    iptables -t nat -A PREROUTING -i wlan0 -p tcp --dport 80 -j DNAT \
        --to "${AP_IP}:${SERVER_PORT:-80}"

    # Prüfen ob hostapd läuft
    sleep 2
    if systemctl is-active --quiet hostapd; then
        log "Access Point '${AP_SSID}' erfolgreich gestartet auf ${AP_IP}"
        exit 0
    else
        log "hostapd konnte nicht gestartet werden."
        start_fallback
    fi
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
    wpa_supplicant -B -i wlan0 -c /tmp/wpa_fallback.conf
    sleep 2

    # DHCP-Adresse holen
    dhclient wlan0 &

    # Warte bis IP vorhanden (max 30s)
    for i in $(seq 1 30); do
        if ip addr show wlan0 | grep -q "inet "; then
            IP=$(ip addr show wlan0 | grep "inet " | awk '{print $2}' | cut -d/ -f1)
            log "Fallback-WLAN verbunden. IP: $IP"
            exit 0
        fi
        sleep 1
    done

    log "Fallback-WLAN: Timeout beim Warten auf IP-Adresse."
    exit 2
}

# Hauptprogramm
start_ap
