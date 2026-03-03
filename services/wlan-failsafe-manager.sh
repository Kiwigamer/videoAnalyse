#!/bin/bash
set -euo pipefail

FLAG_FILE="/var/lib/videoanalyse/enable_ap_once"
STATE_DIR="/var/lib/videoanalyse"
DHCPCD_FILE="/etc/dhcpcd.conf"
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
DNSMASQ_CONF="/etc/dnsmasq.conf"
AP_IP_CIDR="192.168.4.1/24"

BLOCK_START="# videoAnalyse hotspot config start"
BLOCK_END="# videoAnalyse hotspot config end"

log() {
  echo "[wlan-failsafe-manager] $*"
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
}

remove_ap_dhcpcd_block() {
  if [ -f "$DHCPCD_FILE" ] && grep -q "$BLOCK_START" "$DHCPCD_FILE"; then
    sed -i "/$BLOCK_START/,/$BLOCK_END/d" "$DHCPCD_FILE"
  fi
}

add_ap_dhcpcd_block() {
  if ! grep -q "$BLOCK_START" "$DHCPCD_FILE"; then
    cat >> "$DHCPCD_FILE" << EOF
$BLOCK_START
interface wlan0
    static ip_address=$AP_IP_CIDR
    nohook wpa_supplicant
$BLOCK_END
EOF
  fi
}

start_client_mode() {
  log "Switching to client Wi-Fi mode (safe default)."

  systemctl stop hostapd 2>/dev/null || true
  systemctl stop dnsmasq 2>/dev/null || true

  remove_ap_dhcpcd_block

  ip link set wlan0 down 2>/dev/null || true
  ip addr flush dev wlan0 2>/dev/null || true
  ip link set wlan0 up 2>/dev/null || true

  systemctl restart dhcpcd 2>/dev/null || true

  systemctl unmask wpa_supplicant@wlan0 2>/dev/null || true
  systemctl enable wpa_supplicant@wlan0 2>/dev/null || true
  systemctl restart wpa_supplicant@wlan0 2>/dev/null || true
  systemctl restart wpa_supplicant 2>/dev/null || true

  log "Client mode active."
}

start_ap_mode_with_failsafe() {
  log "One-time AP requested. Enabling hotspot mode."

  rm -f "$FLAG_FILE"

  if [ ! -f "$HOSTAPD_CONF" ] || [ ! -f "$DNSMASQ_CONF" ]; then
    log "AP config files missing. Reverting to client mode."
    start_client_mode
    return 1
  fi

  add_ap_dhcpcd_block

  systemctl stop wpa_supplicant@wlan0 2>/dev/null || true
  systemctl stop wpa_supplicant 2>/dev/null || true

  ip link set wlan0 down 2>/dev/null || true
  ip addr flush dev wlan0 2>/dev/null || true
  ip link set wlan0 up 2>/dev/null || true

  systemctl restart dhcpcd 2>/dev/null || true

  systemctl unmask hostapd 2>/dev/null || true
  systemctl enable hostapd dnsmasq 2>/dev/null || true
  systemctl restart hostapd
  systemctl restart dnsmasq

  log "Waiting 15 seconds for AP services..."
  sleep 15

  if systemctl is-active --quiet hostapd && systemctl is-active --quiet dnsmasq; then
    log "AP mode is healthy. Keeping hotspot active."
    return 0
  fi

  log "AP startup failed within 15 seconds. Reverting to client mode."
  systemctl status hostapd --no-pager -l 2>/dev/null | tail -n 20 || true
  systemctl status dnsmasq --no-pager -l 2>/dev/null | tail -n 20 || true
  start_client_mode
  return 1
}

arm_ap_once() {
  ensure_state_dir
  touch "$FLAG_FILE"
  log "AP armed for next boot only."
}

disarm_ap_once() {
  rm -f "$FLAG_FILE"
  log "AP request removed."
}

status_mode() {
  if [ -f "$FLAG_FILE" ]; then
    echo "AP_ON_NEXT_BOOT=1"
  else
    echo "AP_ON_NEXT_BOOT=0"
  fi

  if systemctl is-active --quiet hostapd; then
    echo "HOSTAPD_ACTIVE=1"
  else
    echo "HOSTAPD_ACTIVE=0"
  fi

  if systemctl is-active --quiet dnsmasq; then
    echo "DNSMASQ_ACTIVE=1"
  else
    echo "DNSMASQ_ACTIVE=0"
  fi
}

main() {
  ensure_state_dir

  case "${1:-boot}" in
    boot)
      if [ -f "$FLAG_FILE" ]; then
        start_ap_mode_with_failsafe
      else
        start_client_mode
      fi
      ;;
    arm-ap-once)
      arm_ap_once
      ;;
    disarm-ap)
      disarm_ap_once
      ;;
    force-client)
      disarm_ap_once
      start_client_mode
      ;;
    status)
      status_mode
      ;;
    *)
      echo "Usage: $0 [boot|arm-ap-once|disarm-ap|force-client|status]"
      exit 2
      ;;
  esac
}

main "$@"
