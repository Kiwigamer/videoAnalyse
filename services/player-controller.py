#!/usr/bin/env python3
"""
PiStation Player Controller
Steuert mpv via Unix-IPC-Socket.
"""

import json
import os
import socket
import subprocess
import time
from pathlib import Path


class MPVController:
    def __init__(self, socket_path: str = "/tmp/mpv-socket", media_dir: str = "/home/pi/videos"):
        self.socket_path = socket_path
        self.media_dir   = media_dir
        self.volume      = int(os.environ.get("MPV_VOLUME", 100))
        self._mpv_proc: subprocess.Popen | None = None

    # ------------------------------------------------------------------
    # Prozess-Management
    # ------------------------------------------------------------------

    def start_mpv(self, filepath: str = None) -> bool:
        """Startet mpv als Hintergrundprozess.

        Falls filepath gegeben wird das Video direkt geladen, sonst startet
        mpv im Idle-Modus und wartet auf IPC-Kommandos.
        """
        cmd = [
            "mpv",
            f"--input-ipc-server={self.socket_path}",
            "--fullscreen",
            "--no-terminal",
            "--loop-file=no",
            f"--volume={self.volume}",
            "--keep-open=yes",
        ]

        if filepath:
            cmd.append(filepath)
        else:
            cmd.append("--idle=yes")

        try:
            self._mpv_proc = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            return True
        except FileNotFoundError:
            print("FEHLER: mpv nicht gefunden. Bitte mit apt install mpv installieren.")
            return False
        except Exception as e:
            print(f"FEHLER beim Starten von mpv: {e}")
            return False

    def is_running(self) -> bool:
        """Gibt True zurück, wenn der mpv-Socket existiert und erreichbar ist."""
        if not os.path.exists(self.socket_path):
            return False
        try:
            result = self.send_command("get_property", "pid")
            return isinstance(result, dict)
        except Exception:
            return False

    def ensure_running(self) -> bool:
        """Stellt sicher, dass mpv läuft. Startet es bei Bedarf und wartet
        maximal 5 Sekunden auf den Socket."""
        if self.is_running():
            return True

        self.start_mpv()

        for _ in range(50):  # 5s in 100ms-Schritten
            if os.path.exists(self.socket_path):
                time.sleep(0.1)
                if self.is_running():
                    return True
            time.sleep(0.1)

        return False

    # ------------------------------------------------------------------
    # IPC-Kommunikation
    # ------------------------------------------------------------------

    def send_command(self, *args) -> dict:
        """Sendet ein JSON-IPC-Kommando an den mpv-Socket.

        Gibt die geparste Antwort zurück oder {} bei Fehler.
        """
        payload = json.dumps({"command": list(args)}).encode() + b"\n"
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(2.0)
            sock.connect(self.socket_path)
            sock.sendall(payload)

            # Antwort lesen — mpv sendet eine Zeile JSON
            data = b""
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                data += chunk
                if b"\n" in data:
                    break
            sock.close()

            # Nur letzte vollständige Zeile verwenden (mpv sendet ggf. Events vorher)
            for line in reversed(data.split(b"\n")):
                line = line.strip()
                if line:
                    return json.loads(line)
        except Exception:
            pass
        return {}

    def get_property(self, prop: str):
        """Liest eine mpv-Property. Gibt den Wert oder None zurück."""
        result = self.send_command("get_property", prop)
        if result.get("error") == "success":
            return result.get("data")
        return None

    def set_property(self, prop: str, value) -> bool:
        """Setzt eine mpv-Property."""
        result = self.send_command("set_property", prop, value)
        return result.get("error") == "success"

    # ------------------------------------------------------------------
    # Statusabfrage
    # ------------------------------------------------------------------

    def get_status(self) -> dict:
        """Liest alle relevanten Properties und gibt ein Status-Dict zurück."""
        if not self.is_running():
            return {
                "playing":  False,
                "filename": None,
                "position": 0,
                "duration": 0,
                "percent":  0,
                "paused":   False,
                "speed":    1.0,
                "volume":   self.volume,
            }

        path      = self.get_property("path")
        time_pos  = self.get_property("time-pos")   or 0
        duration  = self.get_property("duration")   or 0
        paused    = self.get_property("pause")      or False
        speed     = self.get_property("speed")      or 1.0
        volume    = self.get_property("volume")     or self.volume
        idle      = self.get_property("idle-active") or False

        playing  = bool(path and not idle)
        filename = Path(path).name if path else None
        percent  = round((time_pos / duration * 100), 1) if duration else 0

        return {
            "playing":  playing,
            "filename": filename,
            "position": round(time_pos, 2),
            "duration": round(duration, 2),
            "percent":  percent,
            "paused":   paused,
            "speed":    speed,
            "volume":   int(volume),
        }

    # ------------------------------------------------------------------
    # Wiedergabe-Steuerung
    # ------------------------------------------------------------------

    def play_file(self, filepath: str) -> bool:
        """Lädt eine Datei und startet die Wiedergabe."""
        result = self.send_command("loadfile", filepath, "replace")
        return result.get("error") == "success"

    def toggle_pause(self) -> bool:
        """Schaltet zwischen Play und Pause um."""
        result = self.send_command("cycle", "pause")
        return result.get("error") == "success"

    def seek(self, seconds: float, mode: str = "relative") -> bool:
        """Springt relativ oder absolut im Video.

        mode: 'relative' oder 'absolute'
        """
        result = self.send_command("seek", seconds, mode)
        return result.get("error") == "success"

    def set_speed(self, speed: float) -> bool:
        """Setzt die Wiedergabegeschwindigkeit (0.25–4.0)."""
        speed = max(0.25, min(4.0, speed))
        return self.set_property("speed", speed)

    def set_volume(self, volume: int) -> bool:
        """Setzt die Lautstärke (0–100)."""
        volume = max(0, min(100, volume))
        self.volume = volume
        return self.set_property("volume", volume)

    def stop(self) -> bool:
        """Stoppt die Wiedergabe."""
        result = self.send_command("stop")
        return result.get("error") == "success"
