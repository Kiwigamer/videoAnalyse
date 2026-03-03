#!/bin/bash
# PiStation Dashboard Starter
# Wird von openbox autostart aufgerufen.

export DISPLAY=:0

LOG_DIR="/var/log/pistation"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/kiosk.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Stderr auch ins Log
exec 2> >(while IFS= read -r line; do log "[STDERR] $line"; done)

log "--- dashboard-start.sh gestartet (PID $$) ---"
log "DISPLAY=$DISPLAY"

# Warte bis der Webserver erreichbar ist
log "Warte auf PiStation Server..."
until curl -s http://localhost/dashboard > /dev/null 2>&1; do
    sleep 1
done
log "Server erreichbar — starte Chromium Kiosk"

# Bildschirmschoner deaktivieren
xset s off
xset s noblank
xset -dpms

# Mauszeiger verstecken
unclutter -idle 0.1 -root &

log "Starte Chromium..."
chromium \
    --kiosk \
    --noerrdialogs \
    --disable-infobars \
    --disable-session-crashed-bubble \
    --disable-restore-session-state \
    --no-first-run \
    --disable-features=TranslateUI \
    --autoplay-policy=no-user-gesture-required \
    --disable-background-networking \
    --disable-default-apps \
    --disable-extensions \
    --disable-sync \
    --disable-translate \
    --metrics-recording-only \
    --safebrowsing-disable-auto-update \
    http://localhost/dashboard
