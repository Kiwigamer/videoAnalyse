#!/usr/bin/env python3
import importlib.util
import os
import threading
from pathlib import Path

import eventlet
from flask import Flask, jsonify, request, send_from_directory
from flask_socketio import SocketIO, emit
from werkzeug.utils import secure_filename


eventlet.monkey_patch()

BASE_DIR = Path(__file__).resolve().parent.parent
MEDIA_DIR = Path(os.getenv("MEDIA_DIR", "/home/pi/videos"))
SERVER_PORT = int(os.getenv("SERVER_PORT", "80"))

ALLOWED_EXTENSIONS = {
    ".mp4",
    ".mkv",
    ".avi",
    ".mov",
    ".webm",
    ".m4v",
    ".mpg",
    ".mpeg",
}


def _load_player_controller():
    module_path = Path(__file__).resolve().parent / "player-controller.py"
    spec = importlib.util.spec_from_file_location("player_controller", str(module_path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


player_module = _load_player_controller()
controller = player_module.build_controller_from_env()

app = Flask(__name__, static_folder=str(BASE_DIR / "web"), static_url_path="")
socketio = SocketIO(app, cors_allowed_origins="*", async_mode="eventlet")

_status_thread_started = False
_status_lock = threading.Lock()


def allowed_file(filename: str) -> bool:
    return Path(filename).suffix.lower() in ALLOWED_EXTENSIONS


def list_videos():
    MEDIA_DIR.mkdir(parents=True, exist_ok=True)
    videos = []
    for file_path in MEDIA_DIR.iterdir():
        if not file_path.is_file():
            continue
        if not allowed_file(file_path.name):
            continue

        stat = file_path.stat()
        videos.append(
            {
                "name": file_path.name,
                "size": stat.st_size,
                "modified": int(stat.st_mtime),
            }
        )

    videos.sort(key=lambda item: item["modified"], reverse=True)
    return videos


def status_loop():
    while True:
        socketio.emit("player_status", controller.get_status())
        socketio.sleep(0.5)


@app.route("/")
def dashboard_page():
    return send_from_directory(app.static_folder, "index.html")


@app.route("/remote")
def remote_page():
    return send_from_directory(app.static_folder, "remote.html")


@app.route("/api/videos", methods=["GET"])
def api_videos():
    return jsonify(list_videos())


@app.route("/api/upload", methods=["POST"])
def api_upload():
    if "file" not in request.files:
        return jsonify({"error": "Missing file field 'file'"}), 400

    incoming = request.files["file"]
    if incoming.filename == "":
        return jsonify({"error": "No selected file"}), 400

    if not allowed_file(incoming.filename):
        return jsonify({"error": "Unsupported file extension"}), 400

    MEDIA_DIR.mkdir(parents=True, exist_ok=True)
    filename = secure_filename(incoming.filename)
    target = MEDIA_DIR / filename

    if target.exists():
        stem = target.stem
        suffix = target.suffix
        count = 1
        while target.exists():
            target = MEDIA_DIR / f"{stem}_{count}{suffix}"
            count += 1

    incoming.save(str(target))
    controller.load_file(str(target))
    controller.pause(False)

    return jsonify({"ok": True, "file": target.name, "status": controller.get_status()})


@app.route("/api/status", methods=["GET"])
def api_status():
    return jsonify(controller.get_status())


@app.route("/api/control", methods=["POST"])
def api_control():
    payload = request.get_json(silent=True) or {}
    action = payload.get("action")

    success = False

    if action == "pause":
        success = controller.pause(True)
    elif action == "play":
        success = controller.pause(False)
    elif action == "toggle_pause":
        success = controller.toggle_pause()
    elif action == "seek":
        success = controller.seek(float(payload.get("time", 0)))
    elif action == "volume":
        success = controller.set_volume(float(payload.get("value", 100)))
    elif action == "stop":
        success = controller.stop()
    elif action == "play_file":
        name = payload.get("name", "")
        file_path = (MEDIA_DIR / name).resolve()
        if file_path.exists() and file_path.parent == MEDIA_DIR.resolve():
            success = controller.load_file(str(file_path))
            if success:
                controller.pause(False)

    status = controller.get_status()
    return jsonify({"ok": success, "status": status}), (200 if success else 400)


@socketio.on("connect")
def on_connect():
    emit("player_status", controller.get_status())


@socketio.on("control")
def on_control(payload):
    action = (payload or {}).get("action")
    value = (payload or {}).get("value")

    if action == "pause":
        controller.pause(True)
    elif action == "play":
        controller.pause(False)
    elif action == "toggle_pause":
        controller.toggle_pause()
    elif action == "seek":
        controller.seek(float(value or 0))
    elif action == "volume":
        controller.set_volume(float(value or 100))

    emit("player_status", controller.get_status(), broadcast=True)


def ensure_status_thread():
    global _status_thread_started
    with _status_lock:
        if not _status_thread_started:
            socketio.start_background_task(status_loop)
            _status_thread_started = True


if __name__ == "__main__":
    ensure_status_thread()
    socketio.run(app, host="0.0.0.0", port=SERVER_PORT)
