"""The App topic's envelope: one JSON object per message (docs/app-protocol.md §1)."""

from __future__ import annotations

import html
import json
import re
from datetime import datetime, timezone

VERSION = 2
# Telegram's cap, in UTF-16 code units once entities are parsed.
MAX_UNITS = 4096
_FENCE = re.compile(r"^\s*```(?:json)?\s*\n?(.*?)\n?\s*```\s*$", re.S)


def now_iso(ts: float | None = None) -> str:
    moment = datetime.fromtimestamp(ts, timezone.utc) if ts is not None else datetime.now(timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def utf16_len(text: str) -> int:
    return len(text.encode("utf-16-le")) // 2


def dumps(obj: dict) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def message(type_: str, **fields) -> dict:
    return {"v": VERSION, "type": type_, **fields}


def render_html(obj: dict) -> str:
    """What the bot sends (parse_mode=HTML): the JSON is the message's plain text."""
    return f'<pre><code class="language-json">{html.escape(dumps(obj), quote=False)}</code></pre>'


def fits(obj: dict) -> bool:
    return utf16_len(dumps(obj)) <= MAX_UNITS


def parse(text: str | None) -> dict | None:
    """An app request, or None when the text is not a protocol message."""
    if not text:
        return None
    body = text.strip()
    match = _FENCE.match(body)
    if match:
        body = match.group(1).strip()
    try:
        obj = json.loads(body)
    except (ValueError, TypeError):
        return None
    if not isinstance(obj, dict) or not isinstance(obj.get("type"), str):
        return None
    return obj


def cut(text: str | None, limit: int) -> str | None:
    if text is None:
        return None
    text = str(text)
    return text if len(text) <= limit else text[: max(0, limit - 1)].rstrip() + "…"


def shrink(obj: dict, lists: list[tuple[str, ...]]) -> dict:
    """Shorten the named lists (paths of keys) from their end, one item at a
    time, until the message fits; a cut list's parent gets "truncated": true."""
    if fits(obj):
        return obj
    obj = json.loads(json.dumps(obj))
    for path in lists:
        parent = obj
        for key in path[:-1]:
            parent = parent.get(key) if isinstance(parent, dict) else None
            if parent is None:
                break
        if not isinstance(parent, dict) or not isinstance(parent.get(path[-1]), list):
            continue
        items = parent[path[-1]]
        while items and not fits(obj):
            items.pop()
            obj["truncated"] = True
        if fits(obj):
            return obj
    return obj
