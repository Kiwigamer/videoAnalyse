#!/bin/bash
set -euo pipefail

FLAG_FILE="/var/lib/videoanalyse/enable_ap_once"
STATE_DIR="/var/lib/videoanalyse"
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
DNSMASQ_CONF="/etc/dnsmasq.conf"

log() {
  echo "[wlan-mode-manager] $*"
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
}

start_ap_mode() {
  log "One-time AP flag found. Switching wlan0 to AP mode for this boot."

  # Clear flag immediately so behavior is one-shot, even if startup fails.
  rm -f "$FLAG_FILE"

  systemctl stop wpa_supplicant@wlan0 2>/dev/null || true
  systemctl stop wpa_supplicant 2>/dev/null || true

  ip link set wlan0 down || true
  ip addr flush dev wlan0 || true
  ip addr add 192.168.11.1/24 dev wlan0 || true
  ip link set wlan0 up || true

  if [ ! -f "$HOSTAPD_CONF" ]; then
    log "Missing $HOSTAPD_CONF"
    exit 1
  fi

  if [ ! -f "$DNSMASQ_CONF" ]; then
    log "Missing $DNSMASQ_CONF"
    exit 1
  fi

  systemctl restart hostapd
  systemctl restart dnsmasq

  log "AP mode active: SSID from hostapd, gateway 192.168.11.1"
}

start_client_mode() {
  log "No AP flag set. Keeping default client Wi-Fi mode for SSH."

  systemctl stop hostapd 2>/dev/null || true
  systemctl stop dnsmasq 2>/dev/null || true

  ip link set wlan0 up || true

  systemctl unmask wpa_supplicant@wlan0 2>/dev/null || true
  systemctl enable wpa_supplicant@wlan0 2>/dev/null || true
  systemctl restart wpa_supplicant@wlan0 2>/dev/null || true

  # dhcpcd handles DHCP on Raspberry Pi OS.
  systemctl restart dhcpcd 2>/dev/null || true
}

arm_ap_once() {
  ensure_state_dir
  touch "$FLAG_FILE"
  log "AP mode armed for NEXT boot only."
}

disarm_ap_once() {
  rm -f "$FLAG_FILE"
  log "AP mode disarmed."
}

status() {
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
        start_ap_mode
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
    status)
      status
      ;;
    *)
      echo "Usage: $0 [boot|arm-ap-once|disarm-ap|status]"
      exit 2
      ;;
  esac
}

main "$@"
