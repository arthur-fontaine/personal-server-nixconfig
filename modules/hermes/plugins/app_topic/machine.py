"""The Mac's own numbers: CPU, memory, storage, power, battery, uptime.

Power comes from IOKit's AppleSmartBattery (`ioreg -a`, no root): on Apple
silicon PowerTelemetryData.SystemPowerIn is the whole Mac's draw from the
adapter, in mW; on battery, voltage × current. `powermetrics` would need
root, which the Hermes account does not have.
"""

from __future__ import annotations

import json
import os
import plistlib
import subprocess
import threading
import time
from pathlib import Path

SAMPLE_EVERY = 60.0
HOURS = 24


def _signed(value) -> int:
    """ioreg prints a negative current as its 64-bit two's complement."""
    value = int(value or 0)
    return value - (1 << 64) if value >= 1 << 63 else value


def battery_info(raw: bytes | None = None) -> dict:
    if raw is None:
        try:
            raw = subprocess.run(["/usr/sbin/ioreg", "-rn", "AppleSmartBattery", "-a"],
                                 capture_output=True, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            raw = b""
    try:
        entries = plistlib.loads(raw) if raw else []
    except Exception:
        entries = []
    if not entries:
        return {}
    b = entries[0]
    telemetry = b.get("PowerTelemetryData") or {}
    on_ac = bool(b.get("ExternalConnected"))
    power = None
    if on_ac and telemetry.get("SystemPowerIn"):
        power = telemetry["SystemPowerIn"] / 1000.0
    else:
        amperage, voltage = _signed(b.get("InstantAmperage", b.get("Amperage", 0))), int(b.get("Voltage") or 0)
        if amperage and voltage:
            power = abs(amperage * voltage) / 1e6
    current, maximum = b.get("CurrentCapacity"), b.get("MaxCapacity")
    pct = None
    if current is not None and maximum:
        # Apple silicon reports CurrentCapacity as a percentage already (MaxCapacity 100).
        pct = round(current * 100 / maximum) if maximum != 100 else int(current)
    temp = b.get("Temperature")
    return {
        "power_w": round(power, 2) if power is not None else None,
        "battery_pct": pct,
        "charging": bool(b.get("IsCharging")),
        "on_ac": on_ac,
        # The battery's own temperature, in hundredths of a degree.
        "battery_temp_c": round(temp / 100, 1) if isinstance(temp, (int, float)) and temp > 0 else None,
    }


def disk_root() -> str:
    # The data volume holds everything that grows; "/" is the sealed system.
    return "/System/Volumes/Data" if os.path.isdir("/System/Volumes/Data") else "/"


class Machine:
    """Samples every minute (on a daemon thread) into hourly averages, kept
    in a file so a restart does not empty the graphs."""

    def __init__(self, state_path: Path, battery=battery_info):
        self.path = Path(state_path)
        self.battery = battery
        self.lock = threading.Lock()
        self.current: dict = {}
        self.hours: list[dict] = []
        self.energy: list[tuple[float, float]] = []  # (time, Wh) per sample, 24 h
        self._bucket: dict | None = None
        try:
            saved = json.loads(self.path.read_text())
            self.hours = saved.get("hours", [])[-HOURS:]
            self.energy = [tuple(e) for e in saved.get("energy", [])]
        except (OSError, ValueError):
            pass

    def sample(self, now: float | None = None) -> dict:
        import psutil

        now = time.time() if now is None else now
        cpu = psutil.cpu_percent(interval=None)
        mem = psutil.virtual_memory()
        disk = psutil.disk_usage(disk_root())
        info = self.battery() or {}
        try:
            load = [round(x, 2) for x in os.getloadavg()]
        except OSError:
            load = None
        current = {
            "cpu_pct": round(cpu, 1), "load": load, "cores": psutil.cpu_count(),
            "ram_used": int(mem.total - mem.available), "ram_total": int(mem.total),
            "disk_used": int(disk.used), "disk_total": int(disk.total),
            "power_w": info.get("power_w"), "battery_pct": info.get("battery_pct"),
            "charging": info.get("charging"), "on_ac": info.get("on_ac"),
            "temp_c": info.get("battery_temp_c"),
            "uptime_s": int(now - psutil.boot_time()),
        }
        with self.lock:
            last = self.energy[-1][0] if self.energy else None
            if current["power_w"] is not None:
                span = min(now - last, 2 * SAMPLE_EVERY) if last else SAMPLE_EVERY
                self.energy.append((now, current["power_w"] * span / 3600.0))
            self.energy = [e for e in self.energy if e[0] > now - 86400]
            hour = int(now // 3600) * 3600
            if self._bucket is None or self._bucket["hour"] != hour:
                if self._bucket is not None:
                    self.hours.append(self._close(self._bucket))
                    self.hours = self.hours[-HOURS:]
                self._bucket = {"hour": hour, "n": 0, "cpu": 0.0, "ram": 0.0, "power": 0.0, "pn": 0}
            b = self._bucket
            b["n"] += 1
            b["cpu"] += current["cpu_pct"]
            b["ram"] += 100.0 * current["ram_used"] / max(1, current["ram_total"])
            if current["power_w"] is not None:
                b["power"] += current["power_w"]
                b["pn"] += 1
            self.current = current
        self._save()
        return current

    @staticmethod
    def _close(b: dict) -> dict:
        n = max(1, b["n"])
        return {"hour": b["hour"], "cpu": round(b["cpu"] / n, 1), "ram": round(b["ram"] / n, 1),
                "power": round(b["power"] / b["pn"], 2) if b["pn"] else None}

    def _save(self) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps({"hours": self.hours, "energy": self.energy[-1500:]}))
            os.replace(tmp, self.path)
        except OSError:
            pass

    def snapshot(self) -> dict:
        with self.lock:
            out = dict(self.current)
            hours = list(self.hours) + ([self._close(self._bucket)] if self._bucket and self._bucket["n"] else [])
            hours = hours[-HOURS:]
            out["energy_kwh_24h"] = round(sum(e[1] for e in self.energy) / 1000.0, 3) if self.energy else None
            out["history"] = {"cpu": [h["cpu"] for h in hours], "ram": [h["ram"] for h in hours],
                              "power": [h["power"] for h in hours]}
        return out

    def run(self, stop: threading.Event) -> None:
        while not stop.is_set():
            try:
                self.sample()
            except Exception:
                pass
            stop.wait(SAMPLE_EVERY)
