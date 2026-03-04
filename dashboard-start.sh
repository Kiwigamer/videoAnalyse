#!/bin/bash
export DISPLAY=:0
xset s off
xset -dpms
xset s noblank
unclutter -idle 0 &
openbox-session &
sleep 2
chromium-browser --kiosk --incognito --noerrdialogs --disable-infobars http://127.0.0.1:${SERVER_PORT:-80}/
