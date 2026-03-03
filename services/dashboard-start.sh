#!/bin/bash
# PiStation Dashboard Starter
# Wird von openbox autostart aufgerufen.

export DISPLAY=:0

# Warte bis der Webserver erreichbar ist
echo "Warte auf PiStation Server..."
until curl -s http://localhost/dashboard > /dev/null 2>&1; do
    sleep 1
done
echo "Server erreichbar — starte Kiosk..."

# Bildschirmschoner deaktivieren
xset s off
xset s noblank
xset -dpms

# Mauszeiger verstecken
unclutter -idle 0.1 -root &

# Chromium im Kiosk-Mode
chromium-browser \
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
