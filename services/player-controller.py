#!/usr/bin/env python3
import json
import os
import socket
import threading
from typing import Any, Dict, Optional


class MpvController:
    def __init__(self, socket_path: str):
        self.socket_path = socket_path
        self._lock = threading.Lock()

    def _send(self, payload: Dict[str, Any], timeout: float = 1.0) -> Optional[Dict[str, Any]]:
        if not os.path.exists(self.socket_path):
            return None

        raw = (json.dumps(payload) + "\n").encode("utf-8")

        with self._lock:
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                    client.settimeout(timeout)
                    client.connect(self.socket_path)
                    client.sendall(raw)

                    buffer = b""
                    while b"\n" not in buffer:
                        chunk = client.recv(4096)
                        if not chunk:
                            break
                        buffer += chunk

                if not buffer:
                    return None

                line = buffer.split(b"\n", 1)[0].decode("utf-8", errors="ignore").strip()
                if not line:
                    return None

                return json.loads(line)
            except (OSError, socket.timeout, json.JSONDecodeError):
                return None

    def command(self, *args: Any) -> Optional[Dict[str, Any]]:
        return self._send({"command": list(args)})

    def get_property(self, name: str) -> Any:
        response = self.command("get_property", name)
        if not response or response.get("error") != "success":
            return None
        return response.get("data")

    def set_property(self, name: str, value: Any) -> bool:
        response = self.command("set_property", name, value)
        return bool(response and response.get("error") == "success")

    def load_file(self, file_path: str) -> bool:
        response = self.command("loadfile", file_path, "replace")
        return bool(response and response.get("error") == "success")

    def pause(self, state: bool) -> bool:
        return self.set_property("pause", state)

    def toggle_pause(self) -> bool:
        current = self.get_property("pause")
        if current is None:
            return False
        return self.pause(not bool(current))

    def seek(self, seconds: float) -> bool:
        response = self.command("set_property", "time-pos", max(0.0, float(seconds)))
        return bool(response and response.get("error") == "success")

    def set_volume(self, volume: float) -> bool:
        response = self.command("set_property", "volume", max(0.0, min(100.0, float(volume))))
        return bool(response and response.get("error") == "success")

    def stop(self) -> bool:
        response = self.command("stop")
        return bool(response and response.get("error") == "success")

    def get_status(self) -> Dict[str, Any]:
        filename = self.get_property("filename")
        time_pos = self.get_property("time-pos")
        duration = self.get_property("duration")
        paused = self.get_property("pause")
        volume = self.get_property("volume")
        idle_active = self.get_property("idle-active")

        connected = os.path.exists(self.socket_path)

        return {
            "connected": connected,
            "filename": filename,
            "time": float(time_pos) if isinstance(time_pos, (int, float)) else 0.0,
            "duration": float(duration) if isinstance(duration, (int, float)) else 0.0,
            "pause": bool(paused) if paused is not None else False,
            "volume": float(volume) if isinstance(volume, (int, float)) else 100.0,
            "idle": bool(idle_active) if idle_active is not None else False,
        }


def build_controller_from_env() -> MpvController:
    socket_path = os.getenv("SOCKET_PATH", "/tmp/mpv-socket")
    return MpvController(socket_path)


if __name__ == "__main__":
    controller = build_controller_from_env()
    print(json.dumps(controller.get_status(), indent=2))
