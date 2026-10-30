"""guard: every action Hermes takes is reviewed first (review.py).

pre_llm_call records, per session, what the user wrote: a turn from a
platform where only the user can write (config.json's trusted_platforms;
Telegram admits only its owner) is the user's. Turns the events daemon or a
webhook starts are not. pre_tool_call asks the decision model about every
action but the read-only ones, and escalates what it does not clear to
Hermes' approval gate: the user's yes in Telegram, a no or a timeout refusing
it (website/docs/user-guide/features/hooks.md, pre_tool_call).
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path

logger = logging.getLogger(__name__)


def _load(home: str):
    from . import systemone

    config = json.loads((Path(home) / "guard" / "config.json").read_text())
    key = os.environ.get(config["key_env"], "") if config.get("key_env") else ""
    model = systemone.Config.from_env({
        "OPENJEV_BASE_URL": config["url"],
        "OPENJEV_MODEL": config["model"],
        "OPENJEV_AUTH_SCHEME": config["auth_scheme"],
        "OPENJEV_API_KEY": key,
        "OPENJEV_TIMEOUT_MS": str(config.get("timeout_ms", 10000)),
    })
    return model, frozenset(config.get("trusted_platforms", ["telegram"]))


class Guard:
    def __init__(self, model, trusted_platforms) -> None:
        from .review import Session

        self.model = model
        self.trusted_platforms = trusted_platforms
        self.sessions: dict[str, Session] = {}
        self._new = Session

    def _session(self, session_id: str):
        return self.sessions.setdefault(session_id or "", self._new())

    def pre_llm_call(self, session_id: str = "", user_message: str = "", platform: str = "", **_):
        session = self._session(session_id)
        session.turn_from_user = platform in self.trusted_platforms
        if session.turn_from_user and user_message:
            session.messages.append(user_message[:2000])

    def pre_tool_call(self, tool_name: str, args: dict, task_id: str = "", session_id: str = "", **_):
        from .review import read_only, review

        if read_only(tool_name):
            return None
        session = self._session(session_id or task_id)
        verdict = review(self.model, session, tool_name, args or {})
        session.actions.append(f"{tool_name}: {'ran' if verdict.run else 'asked the user'} ({verdict.reason})")
        logger.info("guard: %s %s (%s)", tool_name, "runs" if verdict.run else "asks", verdict.reason)
        if verdict.run:
            return None
        return {"action": "approve", "message": f"Auto-review: {verdict.reason}. Run it?"}


def register(ctx) -> None:
    from hermes_constants import get_hermes_home

    guard = Guard(*_load(str(get_hermes_home())))
    ctx.register_hook("pre_llm_call", guard.pre_llm_call)
    ctx.register_hook("pre_tool_call", guard.pre_tool_call)
