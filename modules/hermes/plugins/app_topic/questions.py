"""Questions waiting for the owner, read from the cards Hermes sends.

Every Hermes card with buttons goes through the Telegram adapter's
_send_control_message (approval "ea:", clarify "cl:"); owner_approval's go
through the bot directly ("oa:", "op:") and report here. A question is
answered by pressing one of its buttons, so the app gets the exact callback
data (docs/app-protocol.md §2.1).
"""

from __future__ import annotations

import base64
import html
import re
import threading
import time

from . import speech
from .protocol import cut, now_iso

KINDS = {"ea": "approval", "cl": "clarify", "oa": "approval", "op": "proposal"}
MAX_AGE = 6 * 3600
_PRE = re.compile(r"<pre[^>]*>(?:<code[^>]*>)?(.*?)(?:</code>)?</pre>", re.S)
_TAG = re.compile(r"<[^>]+>")


def html_to_text(text: str) -> str:
    return html.unescape(_TAG.sub("", text or "")).strip()


def keyboard_options(markup) -> list[dict]:
    rows = getattr(markup, "inline_keyboard", None)
    if rows is None and isinstance(markup, dict):
        rows = markup.get("inline_keyboard")
    out = []
    for row in rows or []:
        for button in row:
            label = getattr(button, "text", None) if not isinstance(button, dict) else button.get("text")
            data = getattr(button, "callback_data", None) if not isinstance(button, dict) else button.get("callback_data")
            if not data:
                continue
            data = data if isinstance(data, str) else str(data)
            parts = data.split(":")
            if parts[0] == "ea" and len(parts) >= 3:
                option_id = parts[1]
            elif len(parts) >= 3:
                option_id = parts[-1]
            else:
                option_id = parts[-1]
            out.append({"id": option_id, "label": str(label or ""),
                        "data_b64": base64.b64encode(data.encode()).decode()})
    return out


def question_id(options: list[dict]) -> tuple[str, str] | None:
    """(prefix, id) from the first button's callback data, or None for a
    keyboard that is not a question (a model picker...)."""
    if not options:
        return None
    data = base64.b64decode(options[0]["data_b64"]).decode()
    parts = data.split(":")
    prefix = parts[0]
    if prefix not in KINDS or len(parts) < 3:
        return None
    key = parts[2] if prefix == "ea" else parts[1]
    return prefix, f"{prefix}:{key}"


class Questions:
    def __init__(self, on_change):
        self.on_change = on_change
        self.lock = threading.Lock()
        self.items: dict[str, dict] = {}
        self.summaries: dict[str, str] = {}

    def add_summary(self, command: str, summary: str) -> None:
        with self.lock:
            self.summaries[command.strip()] = summary
            while len(self.summaries) > 50:
                self.summaries.pop(next(iter(self.summaries)))

    def from_card(self, *, chat: int, message_id: int, text_html: str, markup, command: str | None = None,
                  summary: str | None = None) -> dict | None:
        options = keyboard_options(markup)
        found = question_id(options)
        if found is None:
            return None
        prefix, qid = found
        kind = KINDS[prefix]
        plain = html_to_text(text_html)
        if command is None and prefix == "ea":
            match = _PRE.search(text_html or "")
            command = html.unescape(match.group(1)).strip() if match else None
        with self.lock:
            if summary is None and command:
                summary = self.summaries.get(command.strip())
        labels = [o["label"] for o in options]
        item = {
            "id": qid, "kind": kind, "chat": chat, "message_id": message_id,
            "text": cut(plain, 1200), "summary": cut(summary, 300),
            "command": cut(command, 1200) if kind == "approval" else None,
            "spoken": speech.question_spoken(kind, plain if not command else command, summary, labels),
            "options": options, "asked_at": now_iso(), "_t": time.time(),
        }
        if prefix == "cl":
            # The body lists the choices in full; the buttons only say "1", "2"…
            choices = re.findall(r"^\s*(\d+)\.\s+(.+)$", plain, re.M)
            names = {n: c for n, c in choices}
            for option in item["options"]:
                if option["label"] in names:
                    option["label"] = names[option["label"]]
            item["spoken"] = speech.question_spoken(kind, plain.split("\n\n")[0], None,
                                                    [o["label"] for o in item["options"]])
        with self.lock:
            self.items[qid] = item
        self.on_change()
        return item

    def resolve(self, qid: str | None = None, *, chat: int | None = None, message_id: int | None = None,
                kind: str | None = None) -> bool:
        """Drop a question by id, by its message, or the oldest of a kind (in a chat)."""
        with self.lock:
            target = None
            if qid and qid in self.items:
                target = qid
            elif message_id is not None:
                target = next((k for k, v in self.items.items()
                               if v["message_id"] == message_id and (chat is None or v["chat"] == chat)), None)
            elif kind is not None:
                matches = sorted((v["_t"], k) for k, v in self.items.items()
                                 if v["kind"] == kind and (chat is None or v["chat"] == chat))
                target = matches[0][1] if matches else None
            if target is None:
                return False
            del self.items[target]
        self.on_change()
        return True

    def resolve_callback(self, data: str) -> bool:
        """A tap seen on a button (any client): the question it belongs to is answered."""
        parts = (data or "").split(":")
        if len(parts) < 3 or parts[0] not in KINDS:
            return False
        if parts[0] == "cl" and parts[2] == "other":
            return False  # Hermes now waits for a typed answer: still open.
        key = parts[2] if parts[0] == "ea" else parts[1]
        return self.resolve(f"{parts[0]}:{key}")

    def public(self) -> list[dict]:
        now = time.time()
        with self.lock:
            stale = [k for k, v in self.items.items() if now - v["_t"] > MAX_AGE]
            for k in stale:
                del self.items[k]
            items = sorted(self.items.values(), key=lambda v: v["_t"])
            return [{k: v for k, v in item.items() if not k.startswith("_")} for item in items]
