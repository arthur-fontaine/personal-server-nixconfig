"""The pet's mood (docs/app-protocol.md §5), and its files for the app's build.

The pet itself is Hermes' active pet (agent/pet: ~/.hermes/pets/<slug>/,
pet.json + a Codex 8x9 spritesheet). This keeps which one is current and its
version (~/.hermes/app/pet-state.json); its mood follows Hermes' status.
"""

from __future__ import annotations

import json
import os
import shutil
import tempfile
import threading
from pathlib import Path

BEAT = 10.0  # seconds a happy or confused reaction lasts

# The pet mirrors Hermes and nothing else (docs/app-protocol.md §5): no needs,
# no levels, nothing that asks for care or degrades when ignored.
WORKING = {"working": "working", "thinking": "working", "waiting_user": "waiting"}
# Sprite rows, as Hermes' own mapping (agent/pet/state.py) plus the beats.
ANIMATIONS = {"working": "run", "thinking": "review", "waiting_user": "waiting",
              "happy": "jump", "confused": "failed"}


def mood(status: str, beat: str, beat_until: float, now: float) -> str:
    """idle, working, waiting (a question is open), or for BEAT seconds after a
    turn ends: happy (it finished) or confused (it failed). A beat is a
    reaction, not a state: an error left on agent.status does not keep it."""
    if status in WORKING:
        return WORKING[status]
    if beat and now < beat_until:
        return beat
    return "idle"


def animation(status: str, beat: str, beat_until: float, now: float) -> str:
    current = mood(status, beat, beat_until, now)
    return ANIMATIONS.get(status if current in ("working", "waiting") else current, "idle")


class PetState:
    """Which pet is current and its version, on disk; the mirror of the active
    pet for the app's build."""

    def __init__(self, app_dir: Path):
        self.app_dir = Path(app_dir)
        self.path = self.app_dir / "pet-state.json"
        self.lock = threading.RLock()
        self.data = self._load()
        self.beat, self.beat_until = "", 0.0

    def _load(self) -> dict:
        try:
            raw = json.loads(self.path.read_text())
        except (OSError, ValueError):
            raw = {}
        # A file from protocol v2 also has "needs": ignored, and dropped at the next save.
        return {"slug": raw.get("slug", ""), "version": int(raw.get("version", 0))}

    def save(self) -> None:
        with self.lock:
            payload = {"slug": self.data["slug"], "version": self.data["version"]}
            atomic_write(self.path, json.dumps(payload, indent=1).encode())

    def react(self, beat: str, now: float) -> None:
        self.beat, self.beat_until = beat, now + BEAT

    def adopt(self, slug: str) -> int:
        """A new active pet: a new version."""
        with self.lock:
            if slug == self.data["slug"]:
                return self.data["version"]
            self.data.update(slug=slug, version=self.data["version"] + 1)
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
    """Copy the active pet to ~/.hermes/app/pet/ for the sideload build of the app 'hermes' (../../system/sideload.nix):
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
