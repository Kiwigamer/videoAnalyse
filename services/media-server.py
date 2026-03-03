#!/usr/bin/env python3
"""
PiStation Media Server
Flask + Flask-SocketIO Web-Server mit REST-API und Echtzeit-Status via SocketIO
"""

import logging
import os
import json
import sys
import threading
import time
import traceback
from pathlib import Path

from flask import Flask, request, jsonify, send_from_directory, abort
from flask_socketio import SocketIO, emit

# ---------------------------------------------------------------------------
# Logging — schreibt in Datei UND stdout (damit auch journald es sieht)
# ---------------------------------------------------------------------------

LOG_DIR = Path("/var/log/pistation")
LOG_DIR.mkdir(parents=True, exist_ok=True)
LOG_FILE = LOG_DIR / "server.log"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.FileHandler(str(LOG_FILE), encoding="utf-8"),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger("pistation")

# Unbehandelte Exceptions ebenfalls ins Log schreiben
def _handle_exception(exc_type, exc_value, exc_tb):
    if issubclass(exc_type, KeyboardInterrupt):
        sys.__excepthook__(exc_type, exc_value, exc_tb)
        return
    log.critical("Unbehandelte Exception:", exc_info=(exc_type, exc_value, exc_tb))

sys.excepthook = _handle_exception

log.info("=" * 50)
log.info("PiStation Media Server startet")
log.info(f"Python {sys.version}")
log.info(f"Log-Datei: {LOG_FILE}")

# ---------------------------------------------------------------------------
# Konfiguration aus .env laden
# ---------------------------------------------------------------------------

def load_env(path: str):
    """Lädt Schlüssel=Wert Paare aus einer .env-Datei in os.environ."""
    if not os.path.exists(path):
        return
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            os.environ.setdefault(key.strip(), value.strip())


SCRIPT_DIR = Path(__file__).resolve().parent.parent
load_env(str(SCRIPT_DIR / ".env"))

MEDIA_DIR   = Path(os.environ.get("MEDIA_DIR",   "/home/pi/videos"))
SOCKET_PATH = os.environ.get("SOCKET_PATH", "/tmp/mpv-socket")
SERVER_PORT = int(os.environ.get("SERVER_PORT", 80))
MPV_VOLUME  = int(os.environ.get("MPV_VOLUME", 100))
AP_IP       = os.environ.get("AP_IP", "10.42.0.1")

log.info(f"Konfiguration: PORT={SERVER_PORT}, MEDIA_DIR={MEDIA_DIR}, AP_IP={AP_IP}")

ALLOWED_EXTENSIONS = {".mp4", ".mkv", ".avi", ".mov", ".webm"}
MAX_CONTENT_LENGTH = 4 * 1024 * 1024 * 1024  # 4 GB

# ---------------------------------------------------------------------------
# Flask App
# ---------------------------------------------------------------------------

app = Flask(
    __name__,
    static_folder=str(SCRIPT_DIR / "web" / "static"),
    static_url_path="/static",
)
app.config["MAX_CONTENT_LENGTH"] = MAX_CONTENT_LENGTH

socketio = SocketIO(app, cors_allowed_origins="*", async_mode="eventlet")

# Player-Controller laden (Dateiname enthält Bindestrich → importlib)
import importlib.util as _ilu  # noqa: E402
_spec = _ilu.spec_from_file_location(
    "player_controller",
    str(Path(__file__).parent / "player-controller.py"),
)
_mod = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
MPVController = _mod.MPVController

player = MPVController(socket_path=SOCKET_PATH, media_dir=str(MEDIA_DIR))

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

def allowed_file(filename: str) -> bool:
    return Path(filename).suffix.lower() in ALLOWED_EXTENSIONS


def get_server_ip() -> str:
    """Gibt die aktuelle IP-Adresse des Servers zurück."""
    import socket as _socket
    try:
        s = _socket.socket(_socket.AF_INET, _socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return AP_IP

# ---------------------------------------------------------------------------
# Routen — Seiten
# ---------------------------------------------------------------------------

@app.route("/")
def index_remote():
    """Handy Fernbedienung."""
    return send_from_directory(str(SCRIPT_DIR / "web"), "remote.html")


@app.route("/dashboard")
def index_dashboard():
    """HDMI Dashboard."""
    return send_from_directory(str(SCRIPT_DIR / "web"), "index.html")

# ---------------------------------------------------------------------------
# Routen — API
# ---------------------------------------------------------------------------

@app.route("/api/status")
def api_status():
    player.ensure_running()
    status = player.get_status()
    status["server_ip"] = get_server_ip()
    status["ap_ip"] = AP_IP
    return jsonify(status)


@app.route("/api/info")
def api_info():
    return jsonify({
        "server_ip": get_server_ip(),
        "ap_ip": AP_IP,
    })


@app.route("/api/videos")
def api_videos():
    MEDIA_DIR.mkdir(parents=True, exist_ok=True)
    files = sorted(
        f.name for f in MEDIA_DIR.iterdir()
        if f.is_file() and f.suffix.lower() in ALLOWED_EXTENSIONS
    )
    return jsonify(files)


@app.route("/api/upload", methods=["POST"])
def api_upload():
    if "video" not in request.files:
        return jsonify({"success": False, "error": "Kein Datei-Feld 'video'"}), 400

    file = request.files["video"]
    if not file.filename:
        return jsonify({"success": False, "error": "Leerer Dateiname"}), 400
    if not allowed_file(file.filename):
        return jsonify({"success": False, "error": "Dateityp nicht erlaubt"}), 400

    dest_path = MEDIA_DIR / Path(file.filename).name
    try:
        MEDIA_DIR.mkdir(parents=True, exist_ok=True)
        file.save(str(dest_path))
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

    # Automatisch abspielen
    player.ensure_running()
    player.play_file(str(dest_path))

    return jsonify({"success": True, "filename": dest_path.name})


@app.route("/api/play", methods=["POST"])
def api_play():
    data = request.get_json(force=True, silent=True) or {}
    filename = data.get("file", "")
    if not filename:
        return jsonify({"success": False, "error": "Kein Dateiname angegeben"}), 400

    filepath = MEDIA_DIR / Path(filename).name
    if not filepath.exists():
        return jsonify({"success": False, "error": "Datei nicht gefunden"}), 404
    if not allowed_file(filename):
        return jsonify({"success": False, "error": "Dateityp nicht erlaubt"}), 400

    player.ensure_running()
    ok = player.play_file(str(filepath))
    return jsonify({"success": ok})


@app.route("/api/control", methods=["POST"])
def api_control():
    data = request.get_json(force=True, silent=True) or {}
    action = data.get("action", "")
    value  = data.get("value", None)

    player.ensure_running()
    ok = False

    if action == "toggle_pause":
        ok = player.toggle_pause()
    elif action == "seek":
        ok = player.seek(float(value), mode="relative")
    elif action == "seek_absolute":
        ok = player.seek(float(value), mode="absolute")
    elif action == "set_speed":
        ok = player.set_speed(float(value))
    elif action == "set_volume":
        ok = player.set_volume(int(value))
    elif action == "stop":
        ok = player.stop()
    else:
        return jsonify({"success": False, "error": f"Unbekannte Aktion: {action}"}), 400

    return jsonify({"success": ok})


@app.route("/api/videos/<filename>", methods=["DELETE"])
def api_delete_video(filename: str):
    filepath = MEDIA_DIR / Path(filename).name
    if not filepath.exists():
        return jsonify({"success": False, "error": "Datei nicht gefunden"}), 404
    try:
        filepath.unlink()
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500
    return jsonify({"success": True})

# ---------------------------------------------------------------------------
# SocketIO — Status-Polling-Thread
# ---------------------------------------------------------------------------

def status_broadcast_thread():
    """Sendet alle 500ms den aktuellen Player-Status an alle Clients."""
    log.info("Status-Broadcast-Thread gestartet")
    while True:
        try:
            status = player.get_status()
            status["server_ip"] = get_server_ip()
            status["ap_ip"] = AP_IP
            socketio.emit("status_update", status)
        except Exception as e:
            log.warning(f"Status-Broadcast Fehler: {e}")
        time.sleep(0.5)


@socketio.on("connect")
def on_connect():
    log.info(f"Client verbunden: {request.remote_addr}")
    status = player.get_status()
    status["server_ip"] = get_server_ip()
    status["ap_ip"] = AP_IP
    emit("status_update", status)

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    # Hintergrund-Thread für Status-Broadcast
    t = threading.Thread(target=status_broadcast_thread, daemon=True)
    t.start()

    # mpv im Idle-Modus vorstarten
    log.info("Starte mpv im Idle-Modus...")
    if player.ensure_running():
        log.info("mpv bereit")
    else:
        log.warning("mpv konnte nicht gestartet werden — weiter ohne Player")

    log.info(f"Starte Flask-Server auf 0.0.0.0:{SERVER_PORT}")
    try:
        socketio.run(app, host="0.0.0.0", port=SERVER_PORT, use_reloader=False)
    except PermissionError:
        log.critical(
            f"FEHLER: Port {SERVER_PORT} kann nicht gebunden werden (Permission denied).\n"
            "  Lösungen:\n"
            "  1. sudo setcap 'cap_net_bind_service=+ep' /usr/bin/python3\n"
            "  2. Oder SERVER_PORT=8080 in .env setzen\n"
            "  3. Oder AmbientCapabilities=CAP_NET_BIND_SERVICE in pistation-server.service"
        )
        sys.exit(1)
    except OSError as e:
        log.critical(f"FEHLER beim Starten des Servers: {e}")
        sys.exit(1)
    except Exception as e:
        log.critical(f"Unbekannter Fehler: {e}\n{traceback.format_exc()}")
        sys.exit(1)
