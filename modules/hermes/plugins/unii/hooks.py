"""Gateway and tool hooks: sub-chat locks, models, tools and expiry.

Hook contracts: https://github.com/NousResearch/hermes-agent/blob/74885f997bece88c1393bd174b25b32338336cb6/website/docs/user-guide/features/hooks.md
(`pre_gateway_dispatch`, `pre_tool_call`).
"""

from __future__ import annotations

import asyncio
import logging
import os
import re
import threading
import time

from .policy import Chat, write_volume
from .runtime import Runtime
from .volume import WrongPassphrase

logger = logging.getLogger(__name__)

# The memory is the view: searching past sessions would also cross sub-chat walls.
ALWAYS_BLOCKED = {"session_search": "Past sessions are not searchable: the view is your memory, open it with zoom.",
                  "memory": "The memory is the view, which Hermes keeps by itself: say what matters in your reply."}
ALWAYS_ALLOWED = {"zoom", "date", "clarify"}

SWEEP_EVERY = 60.0


def allowed_sender(source) -> bool:
    """Whether the sender is on the platform's allowlist (e.g. WHATSAPP_ALLOWED_USERS, from
    the secrets file), compared on digits so phone and JID forms match. No list: allowed,
    as for Hermes itself."""
    platform = str(getattr(source.platform, "value", source.platform)).upper()
    raw = os.environ.get(f"{platform}_ALLOWED_USERS", "").strip()
    if not raw or raw == "*":
        return True
    allowed = {re.sub(r"\D", "", item) for item in raw.split(",")} - {""}
    for sender in (getattr(source, "user_id", None), getattr(source, "user_id_alt", None)):
        digits = re.sub(r"\D", "", str(sender or "").split("@")[0].split(":")[0])
        if digits and digits in allowed:
            return True
    return False


def _resolve_tools(names) -> set[str]:
    """Toolset names expanded to their tools (toolsets.py); other names are tools."""
    try:
        from toolsets import resolve_toolset
    except Exception:
        resolve_toolset = None
    tools = set()
    for name in names:
        expanded = []
        if resolve_toolset is not None:
            try:
                expanded = resolve_toolset(name)
            except Exception:
                expanded = []
        tools.update(expanded or [name])
    return tools


class Hooks:
    def __init__(self, runtime: Runtime):
        self.runtime = runtime
        self._last_sweep = 0.0
        self._sweep_lock = threading.Lock()

    # ── pre_gateway_dispatch ─────────────────────────────────────────────

    async def _reply(self, gateway, event, text: str) -> None:
        try:
            adapter = gateway.adapters[event.source.platform]
            await adapter.send(event.source.chat_id, text)
        except Exception:
            logger.warning("unii: could not reply in %s", event.source.chat_id, exc_info=True)

    def maybe_sweep(self) -> None:
        now = time.monotonic()
        if now - self._last_sweep < SWEEP_EVERY or not self._sweep_lock.acquire(blocking=False):
            return
        try:
            self._last_sweep = now
            self.runtime.sweep()
        finally:
            self._sweep_lock.release()

    async def pre_gateway_dispatch(self, event, gateway=None, session_store=None, **kwargs):
        """Runs before authorization, for every sender: it only keeps the gateway
        handles, and takes `/sub unlock` from an allowed sender before Hermes
        stores or logs it, since it holds a passphrase."""
        runtime = self.runtime
        runtime.gateway = gateway or runtime.gateway
        runtime.session_store = session_store or runtime.session_store
        await asyncio.to_thread(self.maybe_sweep)

        text = (getattr(event, "text", None) or "").strip()
        if not text.startswith("/sub unlock") or not allowed_sender(event.source):
            return None
        chat = Chat.from_source(event.source)
        passphrase = text[len("/sub unlock"):].strip()
        await self._reply(gateway, event, await asyncio.to_thread(self.unlock, chat, passphrase))
        return {"action": "skip", "reason": "unii-unlock"}

    def post_gateway_admission(self, session_key: str = "", platform: str = "", source=None,
                               message_id: str = "", text: str = "", **kwargs):
        """After authorization: pin the sub-chat's model, and hold its messages while it is locked."""
        chat = Chat.from_session_key(session_key, platform)
        if chat is None or chat.is_main:
            return None
        runtime = self.runtime
        policy, own, _ = runtime.chat_volumes(chat)
        runtime.apply_model(chat, policy)
        if runtime.is_locked(own, policy) and not (text or "").strip().startswith("/sub"):
            return {"action": "handled", "reply": "🔒 This chat is encrypted and locked. Send `/sub unlock <passphrase>`."}
        return None

    def unlock(self, chat: Chat, passphrase: str) -> str:
        if chat.is_main:
            return "The main chat is not encrypted."
        if not passphrase:
            return "Usage: /sub unlock <passphrase>"
        policy, own, _ = self.runtime.chat_volumes(chat)
        if not self.runtime.encrypted(own, policy):
            return "This chat is not encrypted (`/sub set encrypted on` first)."
        try:
            self.runtime.unlock(own, passphrase)
        except WrongPassphrase:
            time.sleep(2)
            return "Wrong passphrase."
        return f"🔓 Unlocked `{own}` until `/sub lock` or the next restart. You can delete your message."

    # ── on_session_reset ─────────────────────────────────────────────────

    def on_session_reset(self, session_id: str = "", old_session_id: str = "", new_session_id: str = "", **kwargs):
        """A /new or /reset in a sub-chat whose ttl is "session" wipes it. The gateway
        fires this once the replacement session exists, so that one is kept."""
        chat = self.runtime.sessions.get(old_session_id or session_id)
        if chat is None or chat.is_main:
            return
        if self.runtime.policies.policy(chat).ttl == "session":
            self.runtime.wipe_chat(chat, reset_routes=False, keep=tuple(s for s in (new_session_id,) if s))

    # ── pre_tool_call ────────────────────────────────────────────────────

    def pre_tool_call(self, tool_name: str, args: dict, task_id: str = "", **kwargs):
        if tool_name in ALWAYS_BLOCKED:
            return {"action": "block", "message": ALWAYS_BLOCKED[tool_name]}
        session_id = kwargs.get("session_id") or task_id
        chat = self.runtime.sessions.get(session_id)
        if chat is None or chat.is_main or tool_name in ALWAYS_ALLOWED:
            return None
        policy = self.runtime.policies.policy(chat)
        if policy.tools is None:
            return None
        if tool_name not in _resolve_tools(policy.tools):
            allowed = ", ".join(policy.tools) or "none"
            return {"action": "block", "message": f"This sub-chat may not use {tool_name} (allowed: {allowed})."}
        return None


def register_sweeper(hooks: Hooks, every: float = 300.0) -> threading.Thread:
    """Expire temporary sub-chats even when no message arrives."""

    def loop():
        while True:
            time.sleep(every)
            try:
                hooks.runtime.sweep()
            except Exception:
                logger.warning("unii: sweep failed", exc_info=True)

    thread = threading.Thread(target=loop, name="unii-sweeper", daemon=True)
    thread.start()
    return thread


__all__ = ["Hooks", "register_sweeper", "write_volume"]
