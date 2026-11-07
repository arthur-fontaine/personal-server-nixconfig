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
    started: float
    messages: list[Message] = field(default_factory=list)
    task: asyncio.Task | None = None


class Journal:
    """Every event the pipeline sent to triage or Hermes, proposed or not, for
    two days (JSON Lines): what Hermes reads when the user asks whether
    something arrived, since only proposals ever reach its chat."""

    TTL = 2 * 86400

    def __init__(self, path: str, clock=time.time):
        self.path, self.clock = path, clock

    def add(self, event: dict, outcome: str) -> None:
        now = self.clock()
        record = {
            "time": datetime.fromtimestamp(now).isoformat(timespec="seconds"),
            "t": now,
            "source": event.get("source"),
            "key": event.get("key"),
            "chat": event.get("chat"),
            "summary": event.get("summary"),
            "messages": event.get("messages"),
            "context": event.get("context") or None,
            "outcome": outcome,
        }
        try:
            with open(self.path) as f:
                kept = [line for line in f if json.loads(line).get("t", 0) > now - self.TTL]
        except (OSError, ValueError):
            kept = []
        kept.append(json.dumps(record, ensure_ascii=False) + "\n")
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            f.writelines(kept)
        os.replace(tmp, self.path)

    def earlier(self, key: str, since: float, limit: int) -> list[str]:
        """The lines this chat's earlier events carried, oldest first: the
        conversation as the daemon saw it, for a source that keeps none it
        can read (Discord), or a thread it could not find."""
        lines: list[str] = []
        try:
            with open(self.path) as f:
                for raw in f:
                    record = json.loads(raw)
                    if record.get("key") == key and record.get("t", 0) >= since:
                        lines.extend(line for line in (record.get("messages") or "").splitlines() if line)
        except (OSError, ValueError):
            return []
        return lines[-limit:]


class Pipeline:
    def __init__(self, *, triage, sink, seen: Seen, batch_seconds: float, max_age_seconds: float,
                 max_batch_seconds: float | None = None, max_chars: int = 4000, clock=time.time,
                 journal: Journal | None = None, history=None):
        self.triage, self.sink, self.seen, self.journal = triage, sink, seen, journal
        # (chat, messages) -> history.Context | None: the conversation before them.
        self.history = history
        self.batch_seconds, self.max_age, self.max_chars = batch_seconds, max_age_seconds, max_chars
        self.max_batch = max_batch_seconds if max_batch_seconds is not None else 5 * batch_seconds
        self.clock = clock
        self.batches: dict[str, Batch] = {}
        # asyncio keeps only weak references to tasks.
        self.tasks: set[asyncio.Task] = set()

    def spawn(self, coroutine) -> asyncio.Task:
        task = asyncio.get_running_loop().create_task(coroutine)
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)
        return task

    def message(self, chat: Chat, message: Message) -> None:
        if not self.seen.add(f"{chat.key}:{message.id}"):
            return
        if self.clock() - message.time > self.max_age:
            log.debug("old message in %s, skipped", chat.key)
            return
        batch = self.batches.setdefault(chat.key, Batch(chat, self.clock()))
        batch.messages.append(message)
        # A quiet window: each message pushes the flush back ("on se voit ?",
        # then "ce soir"), up to max_batch after the first, so a chat that
        # never stops still gets through.
        if batch.task:
            batch.task.cancel()
        wait = min(self.batch_seconds, max(0.0, batch.started + self.max_batch - self.clock()))
        batch.task = self.spawn(self._flush_later(chat.key, wait))

    def own_message(self, chat: Chat) -> None:
        """The user wrote in that chat: they are on it, so nothing to propose."""
        batch = self.batches.pop(chat.key, None)
        if batch and batch.task:
            batch.task.cancel()
            log.info("%s: the user answered, dropped %d message(s)", chat.key, len(batch.messages))

    def notice(self, source: str, key: str, summary: str, details: str = "", *, id: str | None = None,
               screen: bool = True, fail_open: bool = True, triage: str | None = None) -> None:
        """An event that is not a chat message (a HomeKit change, a calendar
        event, a missed call...). `id` dedupes it; `screen` False skips the
        triage (it always matters); `triage` names its profile (triage.py)."""
        if id is not None and not self.seen.add(f"{source}:{id}"):
            return
        event = {"source": source, "key": f"{source}:{key}", "summary": summary,
                 "messages": details[: self.max_chars], "context": "", "reply_hint": "", "is_group": False}
        if triage:
            event["triage"] = triage
        self.spawn(self._send(event, screen, fail_open))

    def system(self, key: str, text: str) -> None:
        """This Mac's own news (disk, power, a service down): trusted and rare,
        sent as written on the system route, with no model at all."""
        if self.seen.add(f"system:{key}"):
            self.spawn(self.sink.post({"key": f"system:{key}", "text": text}, route="system"))

    async def _send(self, event: dict, screen: bool, fail_open: bool) -> None:
        self.seen.save()
        if screen:
            verdict = await self.triage.decide(event, fail_open=fail_open)
            if verdict is None or verdict.get("dropped"):
                why = (verdict or {}).get("dropped") or "nothing for the user"
                log.info("%s: triage says nothing to propose (%s)", event["key"], why)
                self._journal(event, f"not proposed (triage: {why})")
                return
            event["urgency"] = verdict["urgency"]
            if verdict.get("category"):
                event["category"] = verdict["category"]
        else:
            event["urgency"] = "now"
        label = ", ".join(filter(None, (event.get("category"), event["urgency"])))
        self._journal(event, f"proposed to the user ({label})")
        await self.sink.post(event)

    def _journal(self, event: dict, outcome: str) -> None:
        if self.journal is None:
            return
        try:
            self.journal.add(event, outcome)
        except OSError as error:
            log.warning("journal: %s", error)

    async def _flush_later(self, key: str, wait: float) -> None:
        await asyncio.sleep(wait)
        batch = self.batches.pop(key, None)
        if batch:
            await self.flush(batch)

    async def flush(self, batch: Batch) -> None:
        context = None
        if self.history is not None:
            try:
                context = await self.history(batch.chat, batch.messages)
            except Exception as error:
                log.warning("%s: no history (%s)", batch.chat.key, error)
        seen = []
        # A chat keyed on its source alone ("instagram:instagram") is whoever
        # the notification did not name: their lines are not one conversation.
        named = batch.chat.chat_id != batch.chat.source
        if (context is None or not context.earlier) and self.journal is not None and named:
            seen = self.journal.earlier(batch.chat.key, batch.started - self.EARLIER_SECONDS, self.EARLIER_LINES)
        event = self.event(batch, context, seen)
        if context is not None and context.answered:
            log.info("%s: the user answered, dropped %d message(s)", batch.chat.key, len(batch.messages))
            self._journal(event, "not proposed (the user answered in the chat)")
            return
        await self._send(event, True, not batch.chat.is_group)

    def lines(self, messages: list[Message]) -> str:
        today = datetime.fromtimestamp(self.clock()).date()

        def stamp(m: Message) -> str:
            moment = datetime.fromtimestamp(m.time)
            return moment.strftime("%H:%M" if moment.date() == today else "%a %d %b %H:%M")

        text = "\n".join(f"[{stamp(m)}] {m.sender}: {m.text}" for m in messages)
        return "…" + text[-self.max_chars:] if len(text) > self.max_chars else text

    # What the journal gives a chat with no history of its own: the triage
    # keeps eight lines anyway (triage.recent).
    EARLIER_LINES = 8
    EARLIER_SECONDS = 86400

    def event(self, batch: Batch, context=None, seen: list[str] = ()) -> dict:
        chat, messages = batch.chat, batch.messages
        text = self.lines(messages)
        earlier = ""
        if context is not None and context.earlier:
            earlier = ("Earlier in this conversation, oldest first (\"me\" is the user):\n"
                       + self.lines(context.earlier) + "\n\nThe new messages:")
        elif seen:
            # Only what others sent: the user's own replies never reach the daemon here.
            earlier = ("Earlier in this conversation, as it reached the user's assistant, oldest first "
                       "(the user's own replies are not shown):\n" + "\n".join(seen) + "\n\nThe new messages:")
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
            "context": earlier,
            "reply_hint": chat.reply_hint,
        }
