"""The Hermes context engine: every turn is a fresh call on the view.

Implements UniiChat's turn (https://gist.github.com/VictorTaelin/91837951a5ce5b38f341ec1ba1df6449,
section 6) on Hermes' ContextEngine contract
(https://github.com/NousResearch/hermes-agent/blob/74885f997bece88c1393bd174b25b32338336cb6/agent/context_engine.py,
website/docs/developer-guide/context-engine-plugin.md):

- select_context() replaces each request with [system] [view] [this turn], so
  nothing carries over between turns but the view;
- on_turn_complete() logs the turn's messages, word for word, into the chat's
  volume (and the main one, for a sub-chat that writes it);
- zoom and date are the engine's tools.
"""

from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from typing import Any

from agent.context_engine import ContextEngine

from .policy import MAIN, PASSIVE_PLATFORMS, Chat, Policy
from .runtime import Runtime, scrub_session
from .volume import VolumeLocked

logger = logging.getLogger(__name__)

ZOOM = {
    "name": "zoom",
    "description": (
        "Open the line id+n of the view into the two lines of n/2 under it; n = 1 gives the "
        "message whole. n is a power of 2, and id a multiple of n. volume: which view the line "
        "is in (default: this chat's own; \"main\" for the main chat's memory when shown)."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "id": {"type": "integer", "description": "The first message of the line."},
            "n": {"type": "integer", "description": "How many messages the line covers."},
            "volume": {"type": "string", "description": "The volume of the line."},
        },
        "required": ["id", "n"],
    },
}

DATE = {
    "name": "date",
    "description": "The date and time of message id.",
    "parameters": {
        "type": "object",
        "properties": {
            "id": {"type": "integer"},
            "volume": {"type": "string"},
        },
        "required": ["id"],
    },
}


def _text(content: Any) -> str:
    """The text of a message's content; images become a marker."""
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    parts = []
    for part in content:
        if isinstance(part, dict) and part.get("type") == "text":
            parts.append(part.get("text", ""))
        elif isinstance(part, dict):
            parts.append(f"[{part.get('type', 'attachment')}]")
    return "\n".join(parts)


def _prepend(content: Any, prefix: str) -> Any:
    if isinstance(content, list):
        return [{"type": "text", "text": prefix}] + list(content)
    return f"{prefix}{content or ''}"


def _final(message: dict) -> bool:
    return message.get("role") == "assistant" and not message.get("tool_calls")


def turn_start(messages: list[dict], finished: bool) -> int | None:
    """Where the current turn begins: the first user message after the previous final reply."""
    end = len(messages) - 1 if finished else len(messages)
    previous = -1
    for k in range(end - 1, -1, -1):
        if _final(messages[k]):
            previous = k
            break
    for k in range(previous + 1, len(messages)):
        if messages[k].get("role") == "user":
            return k
    return None


class UniiEngine(ContextEngine):
    threshold_percent = 0.95
    emit_automatic_compaction_status = False

    def __init__(self, runtime: Runtime):
        self.runtime = runtime
        self.session_id: str | None = None
        self.chat: Chat | None = None
        self.passive = False
        self._logged: set[str] = set()

    @property
    def name(self) -> str:
        return "unii"

    def clone_for_agent(self) -> "UniiEngine":
        return UniiEngine(self.runtime)

    # ── session ──────────────────────────────────────────────────────────

    def on_session_start(self, session_id: str, **kwargs) -> None:
        platform = kwargs.get("platform") or "cli"
        self.session_id = session_id
        self.chat = Chat.from_session_key(kwargs.get("conversation_id"), platform)
        self.passive = platform in PASSIVE_PLATFORMS or self.chat is None
        if self.chat is not None and not self.passive:
            self.runtime.sessions[session_id] = self.chat
            self.runtime.policies.touch(self.chat, session_id)

    def on_session_reset(self) -> None:
        super().on_session_reset()
        self._logged.clear()

    # A sub-chat with ttl "session" is wiped by the plugin's on_session_reset
    # hook (hooks.py), which fires on an explicit /new or /reset only. The
    # engine's on_session_end also fires when the gateway shuts down or evicts
    # an idle agent, which must not wipe anything.

    # ── the view ─────────────────────────────────────────────────────────

    def _sections(self) -> str:
        """The views this session sees, after waiting for their summaries."""
        if self.passive or self.chat is None:
            names, tags = [MAIN], {MAIN: "chat"}
            policy = None
        else:
            policy, own, names = self.runtime.chat_volumes(self.chat)
            tags = {own: "chat", MAIN: "main"} if own != MAIN else {MAIN: "chat"}
        blocks = []
        for name in names:
            volume = self.runtime.volume(name, policy if name != MAIN else None)
            if not volume.wait_built(volume.count, self.runtime.summary_wait):
                logger.warning("unii: %s still has unsummarized messages", name)
            tag = tags.get(name, "chat")
            blocks.append(f"<{tag}>\n{volume.render()}\n</{tag}>")
        return "\n".join(blocks)

    def _state(self) -> str:
        now = datetime.now(timezone.utc).astimezone().isoformat(timespec="minutes")
        where = "main chat" if self.chat is None or self.chat.is_main else f"sub-chat {self.chat.key}"
        return f"[now: {now}; {where}]\n\n"

    def select_context(self, request_messages, *, conversation_messages=None, incoming_message=None, budget_tokens=0):
        try:
            prefix = self._sections() + "\n\n" + self._state()
        except VolumeLocked:
            return None
        k = turn_start(request_messages, finished=False)
        if k is None:
            return None
        if self.passive:
            # A subagent keeps its own task context; it only gets the view first.
            selected = list(request_messages)
            selected[k] = {**selected[k], "content": _prepend(selected[k].get("content"), prefix)}
            return selected
        system = [m for m in request_messages[:1] if m.get("role") == "system"]
        first = {**request_messages[k], "content": _prepend(request_messages[k].get("content"), prefix)}
        return system + [first] + list(request_messages[k + 1 :])

    # ── logging the turn ─────────────────────────────────────────────────

    def _entries(self, messages: list[dict]) -> list[tuple[str, str]]:
        k = turn_start(messages, finished=True)
        if k is None:
            return []
        out = []
        for message in messages[k:]:
            uid = message.get("message_uid") or f"{id(message)}"
            if uid in self._logged:
                continue
            self._logged.add(uid)
            role = message.get("role")
            if role == "user":
                out.append(("user", _text(message.get("content"))))
            elif role == "assistant":
                if text := _text(message.get("content")).strip():
                    out.append(("hermes", text))
                for call in message.get("tool_calls") or []:
                    fn = call.get("function", {})
                    out.append(("tool", f"{fn.get('name')} {fn.get('arguments') or ''}".strip()))
            elif role == "tool":
                out.append(("echo", _text(message.get("content"))))
        return out

    def on_turn_complete(self, messages, usage=None, **kwargs) -> None:
        if self.passive or self.chat is None:
            return
        policy, own, _ = self.runtime.chat_volumes(self.chat)
        try:
            entries = self._entries(messages)
            for kind, text in entries:
                if not text:
                    continue
                self.runtime.append(own, kind, text, policy)
                if policy.memoryWrite and own != MAIN:
                    self.runtime.append(MAIN, kind, f"[{self.chat.key}] {text}")
            self.runtime.maintain(own)
            if policy.memoryWrite and own != MAIN:
                self.runtime.maintain(MAIN)
        except VolumeLocked:
            logger.warning("unii: %s is locked, the turn was not logged", own)
        self.runtime.policies.touch(self.chat, self.session_id)
        if policy.encrypted and self.session_id:
            scrub_session(self.session_id)

    # ── tools ────────────────────────────────────────────────────────────

    def get_tool_schemas(self):
        return [ZOOM, DATE]

    def _readable(self, requested: str | None) -> tuple[str | None, Policy | None]:
        if self.passive or self.chat is None:
            return (MAIN if requested in (None, MAIN, "chat") else None), None
        policy, own, names = self.runtime.chat_volumes(self.chat)
        name = own if requested in (None, "", "chat") else requested
        return (name if name in names else None), policy

    def handle_tool_call(self, name: str, args: dict, **kwargs) -> str:
        volume_name, policy = self._readable(args.get("volume"))
        if volume_name is None:
            return json.dumps({"error": f"volume {args.get('volume')!r} is not readable from this chat"})
        try:
            volume = self.runtime.volume(volume_name, policy if volume_name != MAIN else None)
        except VolumeLocked:
            return json.dumps({"error": f"{volume_name} is locked: ask the user for /sub unlock"})
        if name == "zoom":
            return json.dumps({"result": volume.zoom(int(args["id"]), int(args["n"]))}, ensure_ascii=False)
        if name == "date":
            return json.dumps({"result": volume.date(int(args["id"]))})
        return super().handle_tool_call(name, args, **kwargs)

    # ── budget ───────────────────────────────────────────────────────────
    # The request is constant-size by construction, so the built-in
    # compaction never needs to run.

    def update_from_response(self, usage: dict) -> None:
        self.last_prompt_tokens = int(usage.get("prompt_tokens") or 0)
        self.last_completion_tokens = int(usage.get("completion_tokens") or 0)
        self.last_total_tokens = int(usage.get("total_tokens") or 0)

    def should_compress(self, prompt_tokens=None) -> bool:
        return False

    def compress(self, messages, current_tokens=None, focus_topic=None, force=False, memory_context=""):
        k = turn_start(messages, finished=False)
        system = [m for m in messages[:1] if m.get("role") == "system"]
        return system + (messages[k:] if k is not None else messages[-2:])
