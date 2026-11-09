"""space: Hermes is told, at its next turn, of the big folders it created
that are about to freeze (modules/hermes/system/access/freeze.py), so it
deletes what is scratch while it still can; once frozen they are its
owner's and stay until he deletes them.

The notice is context added to the turn (pre_llm_call, as app_topic's call
turns: the system prompt and its cache stay as they are), never a turn of
its own, so the owner sees nothing unless Hermes has something to say. A
folder is named once per freeze time. Nothing is deleted here.
"""

from __future__ import annotations

import json
import logging
import time
from pathlib import Path

logger = logging.getLogger(__name__)

STATE: dict = {"config": {}, "noticed": {}, "file": None}


def size(n: float) -> str:
    n = float(n)
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.0f} {unit}" if unit in ("B", "KB") else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


def due(report: dict, config: dict, noticed: dict, now: float) -> list:
    """The upcoming groups big enough and close enough to their freeze, not named yet."""
    out = []
    for g in ((report or {}).get("upcoming") or {}).get("groups") or []:
        at = g.get("freezes_at")
        if at is None or g.get("bytes", 0) < config.get("notice_bytes", 1 << 30):
            continue
        if not now <= at <= now + config.get("notice_window", 3 * 3600):
            continue
        if noticed.get(g["path"]) == at:
            continue
        out.append(g)
    return out


def notice(groups: list, now: float, home: str = "") -> str:
    def where(path: str) -> str:
        return "~" + path[len(home):] if home and path.startswith(home + "/") else path

    items = "; ".join(f"{where(g['path'])} ({size(g['bytes'])}, {g['files']} files, freezing in "
                      f"{max(1, int((g['freezes_at'] - now) // 60))} min)" for g in groups)
    return ("[Resources notice, from this Mac, not the user] These folders you created are about to freeze: "
            f"{items}. Once frozen they are the user's and stay on the disk until he deletes them. Delete now "
            "what is scratch (builds, caches, downloads, clones you are done with); keep what is a result. "
            "Do it without mentioning it unless something needs the user. `hermes-space` shows the rest.")


def pre_llm_call(**_):
    config = STATE["config"]
    try:
        report = json.loads(Path(config.get("report", "")).read_text())
    except (OSError, ValueError):
        return None
    now = time.time()
    groups = due(report, config, STATE["noticed"], now)
    if not groups:
        return None
    for g in groups:
        STATE["noticed"][g["path"]] = g["freezes_at"]
    _save()
    logger.info("space: told Hermes of %d folder(s) about to freeze", len(groups))
    return {"context": notice(groups, now, config.get("home", ""))}


def _save() -> None:
    path = STATE["file"]
    if path is None:
        return
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(STATE["noticed"]))
        tmp.replace(path)
    except OSError:
        logger.debug("space: noticed list not saved", exc_info=True)


def register(ctx) -> None:
    from hermes_constants import get_hermes_home

    home = Path(get_hermes_home())
    try:
        STATE["config"] = json.loads((home / "space" / "config.json").read_text())
    except (OSError, ValueError):
        logger.warning("space: no config; no notice before a freeze")
        return
    STATE["file"] = home / "space" / "noticed.json"
    try:
        STATE["noticed"] = json.loads(STATE["file"].read_text())
    except (OSError, ValueError):
        STATE["noticed"] = {}
    ctx.register_hook("pre_llm_call", pre_llm_call)
