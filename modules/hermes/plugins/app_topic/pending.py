"""The owner's messages a running turn has not taken in yet (docs/app-protocol.md
§2.1 `pending`).

With busy_input_mode "steer" (agent/telegram.nix), a message sent while a
turn runs reaches it at its next tool call, or becomes the next turn. Hermes
used to say so in the chat ("⏩ Steered into current run…"); that bubble is
off (busy_steer_ack_enabled), and the app shows these messages as pending
instead. An entry leaves when the text shows up in a request's conversation
(steered in, or its own turn), or after ``TTL``.
"""

from __future__ import annotations

import threading
import time

from .protocol import now_iso

TTL = 30 * 60
MATCH = 200


def _key(text: str) -> str:
    return " ".join((text or "").split())[:MATCH]


class Pending:
    def __init__(self, on_change):
        self.on_change = on_change
        self.lock = threading.Lock()
        self.items: list[dict] = []

    def add(self, chat: int, message_id: int, text: str, now: float | None = None) -> None:
        now = time.time() if now is None else now
        with self.lock:
            if any(i["chat"] == chat and i["message_id"] == message_id for i in self.items):
                return
            self.items.append({"chat": chat, "message_id": message_id, "since": now_iso(now), "_t": now,
                               "_key": _key(text)})
        self.on_change()

    def taken(self, chat: int, texts: "list[str]", *, turn_start: bool = False) -> None:
        """``texts``: the user rows of a request in ``chat``. A turn's own start
        also takes a message with no text (a photo, a file: queued, never steered)."""
        seen = [" ".join((t or "").split()) for t in texts]
        with self.lock:
            keep = [i for i in self.items if i["chat"] != chat or not (
                (i["_key"] and any(i["_key"] in t for t in seen)) or (turn_start and not i["_key"]))]
            changed = len(keep) != len(self.items)
            self.items = keep
        if changed:
            self.on_change()

    def public(self, now: float | None = None) -> "list[dict]":
        now = time.time() if now is None else now
        with self.lock:
            self.items = [i for i in self.items if now - i["_t"] < TTL]
            return [{"chat": i["chat"], "message_id": i["message_id"], "since": i["since"]} for i in self.items]
