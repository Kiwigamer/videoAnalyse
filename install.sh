#!/bin/bash
# Install dependencies
apt-get update
apt-get install -y network-manager mpv python3-flask python3-pip chromium-browser xorg openbox unclutter python3-websocket python3-python-socketio python3-eventlet
pip3 install flask flask-socketio eventlet --break-system-packages

# Setup directories and shortcuts
mkdir -p /home/pi/videos
cp bin/apON bin/apOFF /usr/local/bin/
chmod +x /usr/local/bin/apON /usr/local/bin/apOFF

# Install services
cp systemd/*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable pistation-server pistation-player pistation-kiosk

echo "Done. Run 'sudo reboot'."
