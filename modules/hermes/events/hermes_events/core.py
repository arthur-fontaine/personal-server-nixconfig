"""The pipeline every source feeds."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone

log = logging.getLogger("hermes_events")


@dataclass(frozen=True)
class Chat:
    source: str  # "whatsapp", "imessage"
    chat_id: str
    name: str
    is_group: bool = False
    # How the main chat answers there, for the proposal's last line.
    reply_hint: str = ""

    @property
    def key(self) -> str:
        return f"{self.source}:{self.chat_id}"


@dataclass(frozen=True)
class Message:
    id: str
    time: float  # Unix seconds
    sender: str
    text: str


def parse_time(value: str) -> float:
    """RFC 3339 / ISO 8601, "Z" included; naive means UTC."""
    moment = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.timestamp()


class Seen:
    """Message ids already handled, kept two days: wacli replays its history
    through the same webhook on reconnects, with no flag to tell it apart."""

    TTL = 2 * 86400

    def __init__(self, path: str, clock=time.time):
        self.path, self.clock = path, clock
        try:
            with open(path) as f:
                self.ids: dict[str, float] = json.load(f)
        except (OSError, ValueError):
            self.ids = {}

    def add(self, key: str) -> bool:
        """True the first time `key` is seen."""
        if key in self.ids:
            return False
        self.ids[key] = self.clock()
        return True

    def save(self) -> None:
        cutoff = self.clock() - self.TTL
        self.ids = {k: t for k, t in self.ids.items() if t >= cutoff}
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.ids, f)
        os.replace(tmp, self.path)


@dataclass
class Batch:
    chat: Chat
    messages: list[Message] = field(default_factory=list)
    task: asyncio.Task | None = None


class Pipeline:
    def __init__(self, *, triage, sink, seen: Seen, batch_seconds: float, max_age_seconds: float,
                 max_chars: int = 4000, clock=time.time):
        self.triage, self.sink, self.seen = triage, sink, seen
        self.batch_seconds, self.max_age, self.max_chars = batch_seconds, max_age_seconds, max_chars
        self.clock = clock
        self.batches: dict[str, Batch] = {}

    def message(self, chat: Chat, message: Message) -> None:
        if not self.seen.add(f"{chat.key}:{message.id}"):
            return
        if self.clock() - message.time > self.max_age:
            log.debug("old message in %s, skipped", chat.key)
            return
        batch = self.batches.setdefault(chat.key, Batch(chat))
        batch.messages.append(message)
        # The window starts at the first message: a burst becomes one event.
        if batch.task is None:
            batch.task = asyncio.get_running_loop().create_task(self._flush_later(chat.key))

    def own_message(self, chat: Chat) -> None:
        """The user wrote in that chat: they are on it, so nothing to propose."""
        batch = self.batches.pop(chat.key, None)
        if batch and batch.task:
            batch.task.cancel()
            log.info("%s: the user answered, dropped %d message(s)", chat.key, len(batch.messages))

    async def _flush_later(self, key: str) -> None:
        await asyncio.sleep(self.batch_seconds)
        batch = self.batches.pop(key, None)
        if batch:
            await self.flush(batch)

    async def flush(self, batch: Batch) -> None:
        self.seen.save()
        event = self.event(batch)
        verdict = await self.triage.decide(event, fail_open=not batch.chat.is_group)
        if verdict is None:
            log.info("%s: triage says nothing to propose", batch.chat.key)
            return
        event["urgency"] = verdict["urgency"]
        await self.sink.post(event)

    def event(self, batch: Batch) -> dict:
        chat, messages = batch.chat, batch.messages
        lines = [
            f"[{datetime.fromtimestamp(m.time).strftime('%H:%M')}] {m.sender}: {m.text}" for m in messages
        ]
        text = "\n".join(lines)
        if len(text) > self.max_chars:
            text = "…" + text[-self.max_chars:]
        where = f"the group {chat.name}" if chat.is_group else chat.name
        count = f"{len(messages)} new messages" if len(messages) > 1 else "A new message"
        return {
            "source": chat.source,
            "key": chat.key,
            "chat": chat.name,
            "chat_id": chat.chat_id,
            "is_group": chat.is_group,
            "summary": f"{count} on {chat.source} from {where}",
            "messages": text,
            "reply_hint": chat.reply_hint,
        }
