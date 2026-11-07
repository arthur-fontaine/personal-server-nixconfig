"""The pet's needs and level (docs/app-protocol.md §5), and its files for the app's build.

The pet itself is Hermes' active pet (agent/pet: ~/.hermes/pets/<slug>/,
pet.json + a Codex 8x9 spritesheet). This keeps what Hermes does not: the
tamagotchi state, in ~/.hermes/app/pet-state.json, advanced lazily from the
time elapsed (no ticker needed).
"""

from __future__ import annotations

import json
import os
import shutil
import tempfile
import threading
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

HOUR = 3600.0
BURST = 10.0  # seconds a "wave"/"jump" animation lasts


def clamp(value: float) -> float:
    return max(0.0, min(100.0, value))


def xp_for_level(level: int) -> int:
    """Total xp needed to reach `level` + 1."""
    return 100 * level * (level + 1) // 2


def level_for(xp: int) -> int:
    level = 1
    while xp >= xp_for_level(level):
        level += 1
    return level


@dataclass
class Needs:
    hunger: float = 0.0
    energy: float = 100.0
    happiness: float = 100.0
    xp: int = 0
    asleep: bool = False
    updated: float = field(default_factory=time.time)
    last_good_day: str = ""
    burst: str = ""
    burst_until: float = 0.0

    @property
    def level(self) -> int:
        return level_for(self.xp)

    def advance(self, now: float, working_seconds: float = 0.0) -> None:
        """Let time pass; `working_seconds` of it Hermes was working."""
        elapsed = max(0.0, now - self.updated)
        working = min(elapsed, max(0.0, working_seconds))
        idle = elapsed - working
        hours, work_h, idle_h = elapsed / HOUR, working / HOUR, idle / HOUR
        self.hunger = clamp(self.hunger + 4 * idle_h + 8 * work_h)
        if self.asleep:
            self.energy = clamp(self.energy + 12 * hours)
            if self.energy >= 100:
                self.asleep = False
        else:
            self.energy = clamp(self.energy - 3 * idle_h - 6 * work_h)
        rate = 5 if (self.hunger > 70 or self.energy < 20) else 2
        self.happiness = clamp(self.happiness - rate * hours)
        self.updated = now
        day = time.strftime("%Y-%m-%d", time.localtime(now))
        if day != self.last_good_day and min(100 - self.hunger, self.energy, self.happiness) > 30 and elapsed < 2 * HOUR:
            # One bonus per day the pet was looked after (checked as it lives, not backfilled).
            if self.last_good_day:
                self.gain(10, now)
            self.last_good_day = day

    def gain(self, xp: int, now: float) -> bool:
        before = self.level
        self.xp += max(0, int(xp))
        if self.level > before:
            self.set_burst("jump", now)
            return True
        return False

    def set_burst(self, animation: str, now: float) -> None:
        self.burst, self.burst_until = animation, now + BURST

    def act(self, action: str, now: float) -> str | None:
        """Apply an action; an error message when refused."""
        if action == "feed":
            if self.hunger < 10:
                return "not hungry"
            self.hunger = clamp(self.hunger - 40)
            self.happiness = clamp(self.happiness + 5)
            self.gain(5, now)
        elif action == "play":
            if self.asleep:
                return "asleep"
            if self.energy < 15:
                return "too tired"
            self.happiness = clamp(self.happiness + 25)
            self.energy = clamp(self.energy - 15)
            self.hunger = clamp(self.hunger + 10)
            self.gain(15, now)
        elif action == "sleep":
            self.asleep = True
        elif action == "wake":
            self.asleep = False
        else:
            return f"unknown action {action!r}"
        return None

    def mood(self, working: bool) -> str:
        if self.asleep:
            return "asleep"
        if self.hunger > 70:
            return "hungry"
        if self.energy < 20:
            return "tired"
        if self.happiness < 30:
            return "sad"
        if working:
            return "focused"
        if self.happiness > 70:
            return "happy"
        return "content"

    def public(self) -> dict:
        return {"hunger": round(self.hunger), "energy": round(self.energy), "happiness": round(self.happiness),
                "xp": self.xp, "level": self.level, "xp_next": xp_for_level(self.level), "asleep": self.asleep}


ANIMATIONS = {"working": "run", "thinking": "review", "waiting_user": "waiting", "error": "failed"}


def animation(needs: Needs, status: str, now: float) -> str:
    if needs.burst and now < needs.burst_until:
        return needs.burst
    if status in ANIMATIONS:
        return ANIMATIONS[status]
    return "idle"


class PetState:
    """The needs on disk, and the mirror of the active pet for the app's build."""

    def __init__(self, app_dir: Path):
        self.app_dir = Path(app_dir)
        self.path = self.app_dir / "pet-state.json"
        self.lock = threading.RLock()
        self.data = self._load()

    def _load(self) -> dict:
        try:
            raw = json.loads(self.path.read_text())
        except (OSError, ValueError):
            raw = {}
        needs = raw.get("needs") or {}
        known = {k: v for k, v in needs.items() if k in Needs.__dataclass_fields__}
        return {"slug": raw.get("slug", ""), "version": int(raw.get("version", 0)), "needs": Needs(**known)}

    def save(self) -> None:
        with self.lock:
            payload = {"slug": self.data["slug"], "version": self.data["version"], "needs": asdict(self.data["needs"])}
            atomic_write(self.path, json.dumps(payload, indent=1).encode())

    @property
    def needs(self) -> Needs:
        return self.data["needs"]

    def adopt(self, slug: str) -> int:
        """A new active pet: a fresh tamagotchi, a new version."""
        with self.lock:
            if slug == self.data["slug"]:
                return self.data["version"]
            self.data.update(slug=slug, version=self.data["version"] + 1, needs=Needs())
            self.save()
            return self.data["version"]


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def manifest(meta: dict, slug: str, version: int) -> dict:
    name = meta.get("displayName") or slug
    return {"id": meta.get("id") or slug, "displayName": name, "name": name,
            "description": meta.get("description", ""), "spritesheetPath": "spritesheet.webp", "version": version}


def icon_png(spritesheet: Path, size: int = 1024, background=(246, 241, 232)) -> bytes:
    """The app icon: the first idle frame, centred on a solid background (an
    iOS icon must be opaque)."""
    import io

    from PIL import Image

    sheet = Image.open(spritesheet).convert("RGBA")
    cols, rows = (8, 9) if sheet.height / sheet.width > 1.0 else (9, 8)
    fw, fh = sheet.width // cols, sheet.height // rows
    frame = sheet.crop((0, 0, fw, fh))
    box = frame.getbbox() or (0, 0, fw, fh)
    frame = frame.crop(box)
    scale = (size * 0.72) / max(frame.width, frame.height)
    frame = frame.resize((max(1, round(frame.width * scale)), max(1, round(frame.height * scale))), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), background + (255,))
    canvas.alpha_composite(frame, ((size - frame.width) // 2, (size - frame.height) // 2))
    out = io.BytesIO()
    canvas.convert("RGB").save(out, format="PNG")
    return out.getvalue()


def mirror(pet_dir: Path, slug: str, version: int, out_dir: Path) -> dict:
    """Copy the active pet to ~/.hermes/app/pet/ for app-delivery's build:
    spritesheet.webp and icon.png first, pet.json last (they watch it)."""
    try:
        meta = json.loads((pet_dir / "pet.json").read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        meta = {}
    declared = str(meta.get("spritesheetPath") or "")
    candidates = ([declared] if declared else []) + ["spritesheet.webp", "spritesheet.png", "sprite.webp", "sprite.png"]
    sheet = next((pet_dir / n for n in candidates if (pet_dir / n).is_file()), None)
    if sheet is None:
        raise FileNotFoundError(f"no spritesheet in {pet_dir}")
    out_dir.mkdir(parents=True, exist_ok=True)
    if sheet.suffix.lower() == ".webp":
        tmp = out_dir / ".spritesheet.webp.tmp"
        shutil.copyfile(sheet, tmp)
        os.replace(tmp, out_dir / "spritesheet.webp")
    else:
        import io

        from PIL import Image

        buf = io.BytesIO()
        Image.open(sheet).save(buf, format="WEBP", lossless=True)
        atomic_write(out_dir / "spritesheet.webp", buf.getvalue())
    atomic_write(out_dir / "icon.png", icon_png(out_dir / "spritesheet.webp"))
    data = manifest(meta, slug, version)
    atomic_write(out_dir / "pet.json", json.dumps(data, indent=2).encode())
    return data
