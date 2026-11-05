"""What was said in a chat before its new messages, from the source's own
store, so the triage and Hermes read a message within its conversation ("Il
faut le faire sur l'ordinateur ?" means nothing alone), the user's own
replies included.

- WhatsApp: `wacli messages list --chat <jid> --before <time>`, read-only, on
  the store `wacli sync` keeps (https://github.com/openclaw/wacli).
- iMessage, SMS: `imsg history --chat-id <id> --end <time> --json`, JSON lines
  of imsg's MessagePayload (Sources/imsg/OutputModels.swift).
- Instagram: the thread, from the logged-in browser (browser.Instagram).
- Discord and the rest: none.
"""

from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone

from .core import Chat, Message, parse_time
from .pollers import run

log = logging.getLogger("hermes_events")


@dataclass
class Context:
    earlier: list[Message] = field(default_factory=list)  # oldest first
    # The user wrote in the chat after its new messages (Instagram, whose
    # own replies the daemon does not see otherwise): they are on it.
    answered: bool = False


def utc(moment: float) -> str:
    return datetime.fromtimestamp(moment, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def whatsapp_earlier(payload: dict, new_ids: set[str]) -> list[Message]:
    found = ((payload.get("data") or {}).get("messages")) or []
    out = []
    for m in found:
        if m.get("MsgID") in new_ids or m.get("ReactionToID") or m.get("Revoked") or m.get("DeletedForMe"):
            continue
        text = m.get("Text") or m.get("DisplayText") or ""
        if m.get("MediaType"):
            text = f"[{m['MediaType']}] {m.get('MediaCaption') or text}".strip()
        if not text:
            continue
        sender = "me" if m.get("FromMe") else (m.get("SenderName") or m.get("ChatName") or "them")
        try:
            moment = parse_time(m["Timestamp"])
        except (KeyError, ValueError):
            continue
        out.append(Message(m.get("MsgID") or "", moment, sender, text))
    return sorted(out, key=lambda m: m.time)


def imessage_earlier(output: str, new_ids: set[str]) -> list[Message]:
    out = []
    for line in output.splitlines():
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if not isinstance(m, dict) or m.get("guid") in new_ids or m.get("is_reaction"):
            continue
        text = m.get("text") or ("[attachment]" if m.get("attachments") else "")
        if not text:
            continue
        sender = "me" if m.get("is_from_me") else (m.get("sender_name") or m.get("sender") or "them")
        try:
            moment = parse_time(m["created_at"])
        except (KeyError, ValueError):
            continue
        out.append(Message(m.get("guid") or "", moment, sender, text))
    return sorted(out, key=lambda m: m.time)


class History:
    """`await history(chat, new_messages)`: the Context, or None when the
    source keeps none or cannot be read (the event goes on without it)."""

    def __init__(self, *, wacli: list[str] | None = None, imsg: list[str] | None = None, instagram=None,
                 limit: int = 15, max_age: float = 7 * 86400, timeout: float = 20, clock=time.time):
        self.wacli, self.imsg, self.instagram = wacli, imsg, instagram
        self.limit, self.max_age, self.timeout, self.clock = limit, max_age, timeout, clock

    async def __call__(self, chat: Chat, messages: list[Message]) -> Context | None:
        if not messages:
            return None
        first = min(m.time for m in messages)
        new_ids = {m.id for m in messages}
        if chat.source == "whatsapp" and self.wacli:
            out = await run(*self.wacli, "--json", "--read-only", "messages", "list", "--chat", chat.chat_id,
                            "--before", utc(first), "--limit", str(self.limit), timeout=self.timeout)
            earlier = whatsapp_earlier(json.loads(out), new_ids)
        elif chat.source == "imessage" and self.imsg:
            out = await run(*self.imsg, "history", "--chat-id", chat.chat_id, "--end", utc(first),
                            "--limit", str(self.limit), "--json", timeout=self.timeout)
            earlier = imessage_earlier(out, new_ids)
        elif chat.source == "instagram" and self.instagram and chat.chat_id.isdigit():
            thread = await self.instagram.thread(chat.chat_id)
            if thread is None:
                return None
            return thread.context(messages, self.limit, self.clock() - self.max_age)
        else:
            return None
        cutoff = self.clock() - self.max_age
        return Context([m for m in earlier if m.time >= cutoff and m.time < first][-self.limit:])
