#!/bin/bash
export DISPLAY=:0
xset s off
xset -dpms
xset s noblank
unclutter -idle 0 &
openbox-session &
sleep 3
# Support both Pi OS names for Chromium
CHROMIUM=$(command -v chromium-browser 2>/dev/null || command -v chromium)
"$CHROMIUM" --kiosk --incognito --noerrdialogs --disable-infobars \
  --disable-session-crashed-bubble --no-first-run \
  http://127.0.0.1:${SERVER_PORT:-80}/
