# PiMediaStation — Raspberry Pi Offline Media Control System

> **Für AI-Agenten:** Dieses Dokument ist eine vollständige Spezifikation. Implementiere alle Dateien exakt wie beschrieben. Abweichungen nur wenn technisch zwingend notwendig.

---

## Übersicht

Ein selbststartendes Medien-Dashboard-System für den Raspberry Pi:

- **HDMI-Dashboard** startet automatisch beim Boot (Chromium Kiosk-Mode)
- **Access Point** wird automatisch aufgebaut (Pi als WLAN-Hotspot), mit Fallback auf normales WLAN
- **Web-App** auf dem Handy zum Hochladen von Videos und Steuern der Wiedergabe
- **Videoplayer** (mpv) läuft im Hintergrund, gesteuert via IPC-Socket
- **Komplett offline**, kein Internet notwendig

---

## Repository-Struktur

```
pi-media-station/
├── README.md
├── install.sh                  # Einmaliges Setup-Skript
├── .env.example                # Konfigurationsvariablen
├── services/
│   ├── ap-manager.sh           # Access Point + Fallback WLAN Manager
│   ├── media-server.py         # Flask Web-Server (API + Static)
│   ├── player-controller.py    # mpv IPC Bridge
│   └── dashboard-start.sh      # Chromium Kiosk Starter
├── web/
│   ├── index.html              # Dashboard (HDMI-Anzeige)
│   ├── remote.html             # Handy-Fernbedienung
│   └── static/
│       ├── dashboard.js
│       ├── remote.js
│       └── style.css
├── systemd/
│   ├── pistation-ap.service
│   ├── pistation-server.service
│   ├── pistation-player.service
│   └── pistation-kiosk.service
└── config/
    ├── hostapd.conf.template
    ├── dnsmasq.conf.template
    └── dhcpcd.conf.append
```

---

## Voraussetzungen

- Raspberry Pi 3, 4 oder 5 (mit eingebautem WLAN)
- Raspberry Pi OS Lite oder Desktop (Bookworm, 64-bit empfohlen)
- HDMI-Monitor angeschlossen
- Internetzugang beim **ersten Setup** (für `apt install`)

---

## Installation & Benutzung

```bash
git clone https://github.com/DEIN_USER/pi-media-station.git
cd pi-media-station
cp .env.example .env
# Optional: nano .env  (SSID, Passwort anpassen)
sudo bash install.sh
sudo reboot
```

Nach dem Reboot:
1. HDMI zeigt das Dashboard
2. WLAN-Netz `PiStation` erscheint (Passwort: `mediastation`)
3. Handy verbindet sich, öffnet `http://10.42.0.1` → Fernbedienung

---

## Datei-Spezifikationen

---

### `.env.example`

```env
# WLAN Access Point Konfiguration
AP_SSID=PiStation
AP_PASSWORD=mediastation
AP_CHANNEL=6
AP_IP=10.42.0.1
AP_DHCP_RANGE_START=10.42.0.10
AP_DHCP_RANGE_END=10.42.0.50

# Fallback WLAN (normales Heimnetzwerk)
FALLBACK_WIFI_SSID=MeinHeimNetz
FALLBACK_WIFI_PASSWORD=MeinPasswort

# Server
SERVER_PORT=80
MEDIA_DIR=/home/pi/videos
SOCKET_PATH=/tmp/mpv-socket

# Player
MPV_VOLUME=100
```

---

### `install.sh`

**Zweck:** Wird einmalig als root ausgeführt. Installiert alle Pakete, schreibt Konfigdateien, aktiviert systemd-Services.

**Schritte in Reihenfolge:**

1. **Pakete installieren:**
   ```bash
   apt-get update
   apt-get install -y \
     mpv \
     python3-flask \
     python3-pip \
     hostapd \
     dnsmasq \
     chromium-browser \
     xorg \
     openbox \
     unclutter \
     python3-websocket \
     python3-python-socketio \
     python3-eventlet
   pip3 install flask flask-socketio eventlet --break-system-packages
   ```

2. **`.env` laden** und Variablen exportieren.

3. **Verzeichnisse erstellen:**
   - `$MEDIA_DIR` (z.B. `/home/pi/videos`)
   - `/var/log/pistation/`

4. **`hostapd.conf` aus Template generieren** (Variablen ersetzen), nach `/etc/hostapd/hostapd.conf` kopieren. In `/etc/default/hostapd` setzen: `DAEMON_CONF="/etc/hostapd/hostapd.conf"`

5. **`dnsmasq.conf` aus Template generieren**, bestehende Config sichern, neue nach `/etc/dnsmasq.conf` schreiben.

6. **`dhcpcd.conf` Append** — fügt statische IP für `wlan0` hinzu, aber **nur wenn kein Fallback-WLAN konfiguriert ist** (siehe ap-manager.sh für dynamisches Switching).

7. **Alle 4 systemd-Service-Dateien** nach `/etc/systemd/system/` kopieren.

8. **systemd reload** + alle 4 Services enablen (nicht starten — erst nach Reboot):
   ```bash
   systemctl daemon-reload
   systemctl enable pistation-ap pistation-server pistation-player pistation-kiosk
   ```

9. **Autostart für X11:**
   - `/etc/X11/Xwrapper.config`: `allowed_users=anybody`
   - openbox autostart schreiben (startet dashboard-start.sh)

10. **Abschlussmeldung:** "Installation abgeschlossen. Bitte neu starten: sudo reboot"

---

### `services/ap-manager.sh`

**Zweck:** Startet den Access Point. Falls das Starten fehlschlägt oder `FALLBACK_WIFI_SSID` gesetzt ist, versucht es Fallback-WLAN.

**Logik (Pseudocode):**

```
source /pfad/zu/.env

function start_ap():
    systemctl stop wpa_supplicant
    ip link set wlan0 down
    ip addr flush dev wlan0
    ip addr add $AP_IP/24 dev wlan0
    ip link set wlan0 up
    systemctl start hostapd
    systemctl start dnsmasq
    
    # IP-Forwarding für captive-portal-ähnliches DNS
    iptables -t nat -A PREROUTING -i wlan0 -p tcp --dport 80 -j DNAT --to $AP_IP:$SERVER_PORT
    
    if systemctl is-active hostapd → OK: log "AP gestartet", exit 0
    else: log "AP fehlgeschlagen", → start_fallback()

function start_fallback():
    if $FALLBACK_WIFI_SSID ist leer: log "Kein Fallback konfiguriert", exit 1
    
    systemctl stop hostapd dnsmasq
    
    # wpa_supplicant Config schreiben
    wpa_passphrase "$FALLBACK_WIFI_SSID" "$FALLBACK_WIFI_PASSWORD" > /tmp/wpa_fallback.conf
    wpa_supplicant -B -i wlan0 -c /tmp/wpa_fallback.conf
    dhclient wlan0
    
    # Warte bis IP da (max 30s)
    for i in 1..30:
        if ip addr show wlan0 hat inet: log "Fallback verbunden", exit 0
        sleep 1
    
    log "Fallback fehlgeschlagen"
    exit 2

start_ap()
```

---

### `services/media-server.py`

**Zweck:** Flask-Webserver mit Flask-SocketIO. Stellt API und statische Webseiten bereit.

**Imports:** `flask`, `flask_socketio`, `os`, `json`, `subprocess`, `threading`, `time`, `pathlib`

**Konfiguration:** Lädt `.env` via `python-dotenv` oder manuell mit `os.environ`.

**Routen:**

| Method | Route | Beschreibung |
|--------|-------|--------------|
| GET | `/` | Liefert `web/remote.html` (Handy-Fernbedienung) |
| GET | `/dashboard` | Liefert `web/index.html` (HDMI-Dashboard) |
| GET | `/api/status` | Gibt aktuellen Player-Status als JSON zurück |
| GET | `/api/videos` | Liste aller `.mp4`, `.mkv`, `.avi`, `.mov` Dateien in `MEDIA_DIR` |
| POST | `/api/upload` | Nimmt Datei entgegen, speichert in `MEDIA_DIR`, startet Wiedergabe |
| POST | `/api/play` | Body: `{"file": "name.mp4"}` — startet/wechselt Video |
| POST | `/api/control` | Body: `{"action": "...", "value": ...}` — steuert mpv |
| DELETE | `/api/videos/<filename>` | Löscht Video-Datei |

**SocketIO Events (Server → Client):**
- `status_update` — wird alle 500ms gesendet mit aktuellem Player-Zustand

**`/api/status` Response-Format:**
```json
{
  "playing": true,
  "filename": "video.mp4",
  "position": 42.5,
  "duration": 120.0,
  "percent": 35.4,
  "paused": false,
  "speed": 1.0,
  "volume": 100
}
```

Falls kein Video läuft:
```json
{
  "playing": false,
  "filename": null,
  "position": 0,
  "duration": 0,
  "percent": 0,
  "paused": false,
  "speed": 1.0,
  "volume": 100
}
```

**`/api/control` Actions:**

| action | value | Beschreibung |
|--------|-------|--------------|
| `toggle_pause` | — | Play/Pause umschalten |
| `seek` | Sekunden (Float, +/-) | Relativ springen |
| `seek_absolute` | Sekunden (Float) | Absolut springen |
| `set_speed` | Float (0.25–2.0) | Wiedergabegeschwindigkeit |
| `set_volume` | Int (0–100) | Lautstärke |
| `stop` | — | Wiedergabe stoppen |

**Upload-Handling:**
- Max Dateigröße: 4GB (`MAX_CONTENT_LENGTH`)
- Erlaubte Endungen: `.mp4`, `.mkv`, `.avi`, `.mov`, `.webm`
- Nach erfolgreichem Upload → automatisch abspielen via player-controller

**Status-Polling-Thread:**
- Läuft als Hintergrund-Thread
- Liest alle 500ms den mpv-Socket
- Sendet via `socketio.emit('status_update', data)` an alle Clients

---

### `services/player-controller.py`

**Zweck:** Python-Modul/Klasse, die mpv über den IPC-Socket (`/tmp/mpv-socket`) steuert.

**Klasse `MPVController`:**

```python
class MPVController:
    def __init__(self, socket_path: str, media_dir: str):
        ...
    
    def start_mpv(self, filepath: str = None) -> bool:
        """Startet mpv als Subprocess im Hintergrund.
        Argumente: --input-ipc-server=SOCKET_PATH --fullscreen --no-terminal
        --loop=no --volume=MPV_VOLUME
        Falls filepath gegeben: spielt dieses Video ab.
        Falls nicht: mpv startet im Idle-Modus (--idle=yes)
        Gibt True zurück wenn erfolgreich gestartet."""
    
    def send_command(self, *args) -> dict:
        """Schickt JSON-IPC-Kommando an mpv.
        Format: {"command": [...args]}
        Verbindet per Unix-Socket, sendet, liest Antwort.
        Gibt geparste JSON-Antwort zurück oder {} bei Fehler."""
    
    def get_property(self, prop: str) -> any:
        """Liest mpv-Property. Gibt Wert zurück oder None bei Fehler."""
    
    def set_property(self, prop: str, value) -> bool:
        """Setzt mpv-Property."""
    
    def get_status(self) -> dict:
        """Liest alle relevanten Properties auf einmal:
        - path, time-pos, duration, pause, speed, volume, idle-active
        Gibt status-dict zurück (gleiches Format wie /api/status)"""
    
    def play_file(self, filepath: str) -> bool:
        """Lädt und spielt Datei ab (loadfile Kommando)."""
    
    def toggle_pause(self) -> bool: ...
    
    def seek(self, seconds: float, mode: str = "relative") -> bool:
        """mode: 'relative' oder 'absolute'"""
    
    def set_speed(self, speed: float) -> bool:
        """Clamp auf 0.25–4.0"""
    
    def set_volume(self, volume: int) -> bool:
        """Clamp auf 0–100"""
    
    def stop(self) -> bool:
        """stop Kommando an mpv"""
    
    def is_running(self) -> bool:
        """Prüft ob mpv-Socket existiert und erreichbar ist."""
    
    def ensure_running(self) -> bool:
        """Falls mpv nicht läuft: starte es im Idle-Modus.
        Warte bis Socket verfügbar (max 5s). Gib True zurück wenn bereit."""
```

**mpv IPC Protokoll:**
```python
# Kommando senden:
import socket, json
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(socket_path)
sock.send(json.dumps({"command": ["get_property", "time-pos"]}).encode() + b"\n")
response = sock.recv(4096)
data = json.loads(response)
# data = {"data": 42.5, "error": "success"}
```

---

### `services/dashboard-start.sh`

**Zweck:** Wird von openbox autostart aufgerufen. Startet Chromium im Kiosk-Mode auf dem HDMI-Display.

```bash
#!/bin/bash
# Warte bis Server erreichbar
until curl -s http://localhost/dashboard > /dev/null 2>&1; do
    sleep 1
done

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
    http://localhost/dashboard
```

---

### `web/index.html` (HDMI Dashboard)

**Zweck:** Vollbild-Dashboard auf dem angeschlossenen Monitor. Zeigt Wiedergabestatus.

**Design:** Dunkles Theme, große Schrift, gut lesbar aus Distanz.

**Layout:**
```
┌─────────────────────────────────────────┐
│  🎬 PiMediaStation          [IP-Adresse] │
├─────────────────────────────────────────┤
│                                         │
│   [KEIN VIDEO]  oder  [▶ Dateiname.mp4] │
│                                         │
│   ████████████░░░░░░░░  35%             │
│   00:42 / 02:00                         │
│                                         │
│   Geschwindigkeit: 1.0x   Lautstärke: 80│
│                                         │
│   Verbinde mit: PiStation               │
│   Öffne: http://10.42.0.1              │
├─────────────────────────────────────────┤
│  Verbundene Geräte: 1                   │
└─────────────────────────────────────────┘
```

**Technisch:**
- Verbindet sich via Socket.IO zu `http://localhost`
- Empfängt `status_update` Events
- Aktualisiert UI ohne Reload
- Zeigt "Kein Video vorhanden" wenn `playing === false`
- Zeigt QR-Code mit `http://AP_IP` (via qrcode.js CDN oder selbst generiert)
- Kein Reload, kein Scrollen, kein Cursor

---

### `web/remote.html` (Handy-Fernbedienung)

**Zweck:** Mobile-optimierte Steuerungsseite. Wird auf dem Handy geöffnet.

**Tabs / Sektionen:**

**1. Steuerung:**
```
┌────────────────────────────────┐
│  ▶ video.mp4    00:42 / 02:00  │
│  ████████░░░░░░░░  35%         │
│  [Timeline Slider]             │
├────────────────────────────────┤
│  [⏮ -60s] [⏪ -10s] [⏪ -5s]  │
│       [⏸ Pause / ▶ Play]       │
│  [+5s ⏩] [+10s ⏩] [+60s ⏭] │
├────────────────────────────────┤
│  Geschwindigkeit:              │
│  [0.25] [0.5] [1x] [1.5] [2x] │
├────────────────────────────────┤
│  Lautstärke: ──●────────  80   │
└────────────────────────────────┘
```

**2. Videos:**
```
┌────────────────────────────────┐
│  [📂 Video hochladen]          │
│  Fortschritt: ████░░ 60%       │
├────────────────────────────────┤
│  Vorhandene Videos:            │
│  ▶ film1.mp4      [▶] [🗑]   │
│  ▶ vortrag.mkv   [▶] [🗑]   │
└────────────────────────────────┘
```

**Technisch:**
- Vanilla JS, kein Framework (für Kompatibilität)
- Socket.IO für Live-Status
- Fetch API für Uploads mit Progress-Event
- Touch-optimiert (große Buttons, min 48px)
- `viewport: width=device-width, initial-scale=1`
- Timeline-Slider: `input[type=range]`, sendet `seek_absolute` beim Loslassen (nicht während Ziehen)

---

### `web/static/dashboard.js`

```javascript
// Socket.IO verbinden
const socket = io();

// Status-Update empfangen und UI aktualisieren
socket.on('status_update', (status) => {
    updateDashboard(status);
});

function updateDashboard(status) {
    if (!status.playing) {
        // Zeige "Kein Video vorhanden" Screen
    } else {
        // Zeige Videoinformationen, Timeline, etc.
        // Formatiere Zeit: formatTime(status.position) + " / " + formatTime(status.duration)
    }
}

function formatTime(seconds) {
    // Gibt "MM:SS" oder "HH:MM:SS" zurück
}

// Alle 5s eigene IP-Adresse abrufen und anzeigen
async function fetchAndShowIP() {
    const res = await fetch('/api/status');
    // IP aus Response-Header oder separatem Endpunkt
}
```

---

### `web/static/remote.js`

```javascript
const socket = io();
let currentStatus = {};
let isSeeking = false; // True während Slider gezogen wird

socket.on('status_update', (status) => {
    currentStatus = status;
    if (!isSeeking) updateRemote(status);
});

// Control-Button Handler
async function sendControl(action, value = null) {
    const body = { action };
    if (value !== null) body.value = value;
    await fetch('/api/control', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify(body)
    });
}

// Upload mit Fortschritt
async function uploadFile(file) {
    const formData = new FormData();
    formData.append('video', file);
    
    const xhr = new XMLHttpRequest();
    xhr.upload.onprogress = (e) => {
        const percent = (e.loaded / e.total * 100).toFixed(0);
        updateProgressBar(percent);
    };
    xhr.open('POST', '/api/upload');
    xhr.send(formData);
}

// Timeline Slider
slider.addEventListener('input', () => { isSeeking = true; });
slider.addEventListener('change', () => {
    isSeeking = false;
    sendControl('seek_absolute', parseFloat(slider.value));
});

// Video laden
async function playVideo(filename) {
    await fetch('/api/play', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({ file: filename })
    });
}

// Video-Liste laden
async function loadVideoList() {
    const res = await fetch('/api/videos');
    const videos = await res.json();
    renderVideoList(videos);
}
```

---

### `systemd/pistation-ap.service`

```ini
[Unit]
Description=PiStation Access Point Manager
After=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=/home/pi/pi-media-station/.env
ExecStart=/home/pi/pi-media-station/services/ap-manager.sh
ExecStop=/bin/bash -c 'systemctl stop hostapd dnsmasq; ip addr flush dev wlan0'
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

---

### `systemd/pistation-server.service`

```ini
[Unit]
Description=PiStation Media Server
After=network.target pistation-ap.service
Requires=pistation-ap.service

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/pi-media-station
EnvironmentFile=/home/pi/pi-media-station/.env
ExecStart=/usr/bin/python3 services/media-server.py
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

---

### `systemd/pistation-player.service`

```ini
[Unit]
Description=PiStation MPV Player Daemon
After=graphical.target

[Service]
Type=simple
User=pi
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/1000
ExecStart=/usr/bin/mpv --idle=yes --input-ipc-server=/tmp/mpv-socket \
          --fullscreen=no --no-terminal --loop-file=no \
          --volume=100 --keep-open=yes
Restart=always
RestartSec=2
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical.target
```

> **Hinweis:** mpv läuft hier im Hintergrund ohne Video und wartet auf IPC-Kommandos. Das Kiosk-Dashboard zeigt den Status separat.

---

### `systemd/pistation-kiosk.service`

```ini
[Unit]
Description=PiStation Kiosk Dashboard
After=graphical-session.target pistation-server.service
Requires=pistation-server.service

[Service]
Type=simple
User=pi
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/pi/.Xauthority
ExecStartPre=/bin/sleep 5
ExecStart=/home/pi/pi-media-station/services/dashboard-start.sh
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical.target
```

---

### `config/hostapd.conf.template`

```
interface=wlan0
driver=nl80211
ssid=${AP_SSID}
hw_mode=g
channel=${AP_CHANNEL}
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${AP_PASSWORD}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
```

---

### `config/dnsmasq.conf.template`

```
interface=wlan0
dhcp-range=${AP_DHCP_RANGE_START},${AP_DHCP_RANGE_END},255.255.255.0,24h
domain=local
address=/#/${AP_IP}
bogus-priv
```

> `address=/#/${AP_IP}` leitet alle DNS-Anfragen auf den Pi um → captive-portal-ähnliches Verhalten. Handy öffnet automatisch den Browser.

---

### `config/dhcpcd.conf.append`

```
interface wlan0
static ip_address=${AP_IP}/24
nohook wpa_supplicant
```

> Wird von `install.sh` an `/etc/dhcpcd.conf` angehängt — aber **nur im AP-Modus** (wird bei Fallback übersprungen).

---

## API-Referenz (Zusammenfassung)

| Endpoint | Method | Request | Response |
|----------|--------|---------|----------|
| `/api/status` | GET | — | Status-Objekt |
| `/api/videos` | GET | — | `["video1.mp4", ...]` |
| `/api/upload` | POST | multipart/form-data, field `video` | `{"success": true, "filename": "..."}` |
| `/api/play` | POST | `{"file": "name.mp4"}` | `{"success": true}` |
| `/api/control` | POST | `{"action": "toggle_pause"}` | `{"success": true}` |
| `/api/videos/<name>` | DELETE | — | `{"success": true}` |

---

## Fehlerbehandlung & Fallbacks

### WLAN-Fallback

In `ap-manager.sh`:
- Wenn `hostapd` nicht startet (z.B. WLAN-Chip belegt), automatisch zu normalem WLAN wechseln
- `FALLBACK_WIFI_SSID` und `FALLBACK_WIFI_PASSWORD` in `.env` konfigurieren
- Bei Fallback: Server läuft auf der vom Router zugewiesenen IP
- Dashboard zeigt diese IP an (aus `/api/status` oder separatem `/api/info` Endpunkt)

### mpv-Absturz

- `pistation-player.service` hat `Restart=always` — mpv startet automatisch neu
- `player-controller.py` hat `ensure_running()` — baut Socket-Verbindung neu auf
- API gibt `{"playing": false}` zurück solange mpv nicht erreichbar

### Upload-Fehler

- Dateityp-Prüfung server-seitig
- Maximale Dateigröße konfigurierbar
- Unvollständige Uploads werden gelöscht

---

## Logs

```bash
# Alle PiStation Services
journalctl -u pistation-ap -u pistation-server -u pistation-player -u pistation-kiosk -f

# Einzeln
journalctl -u pistation-server -f
```

---

## Bekannte Einschränkungen

- Nur ein Video gleichzeitig
- Kein Audio-Routing (HDMI-Audio)
- Raspberry Pi Zero / Zero 2 W: WLAN und AP gleichzeitig ist eingeschränkt (nutze ggf. USB-WLAN-Stick für AP)
- mpv muss auf einem X11-Display laufen — Wayland-Konfiguration erfordert Anpassungen

---

## Erweiterungsideen (nicht im Scope)

- Playlist-Unterstützung
- Passwortschutz für Web-Interface
- HTTPS
- Thumbnail-Vorschau
- Untertitel-Unterstützung