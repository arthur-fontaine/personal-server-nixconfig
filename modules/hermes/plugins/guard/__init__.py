"""guard: every action Hermes takes is reviewed first (review.py).

pre_llm_call records, per session, what the user wrote: a turn from a
platform where only the user can write (config.json's trusted_platforms;
Telegram admits only its owner) is the user's, and so is a cron job's, which
exists only because its creation passed this review. Turns the events daemon
or a webhook starts are not. A subagent inherits its parent's. All of it is in
memory: after a restart, the first actions of a chat ask once. pre_tool_call asks the decision model about every
action but the read-only ones, and escalates what it does not clear to
Hermes' approval gate: the user's yes in Telegram, a no or a timeout refusing
it (website/docs/user-guide/features/hooks.md, pre_tool_call).
"""

from __future__ import annotations

import hashlib
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
    return model, frozenset(config.get("trusted_platforms", ["telegram", "cron"]))


class Guard:
    def __init__(self, model, trusted_platforms) -> None:
        from .review import Session

        self.model = model
        self.trusted_platforms = trusted_platforms
        self.sessions: dict[str, Session] = {}
        self._new = Session

    def _session(self, session_id: str):
        return self.sessions.setdefault(session_id or "", self._new())

    def pre_llm_call(
        self, session_id: str = "", user_message: str = "", platform: str = "", parent_session_id: str = "", **_
    ):
        session = self._session(session_id)
        parent = self.sessions.get(parent_session_id) if parent_session_id else None
        if parent is not None and not session.messages:
            # A subagent (delegate_task) works for its parent's turn: what the
            # user wrote there, and whether that turn was theirs, carry over.
            session.messages.extend(parent.messages)
            session.turn_from_user = parent.turn_from_user
            return
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
        # What the user's "Always" remembers (tools/approval.py, rule_key): a
        # tool for its bounded risks; a high-risk action only as it is, so
        # always sending to Thierry is not always sending.
        grain = verdict.risk if verdict.risk in {"low", "medium"} else hashlib.sha256(
            json.dumps(args or {}, sort_keys=True, default=str).encode()).hexdigest()[:16]
        return {
            "action": "approve",
            "message": f"Auto-review: {verdict.reason}. Run it?",
            "rule_key": f"guard:{tool_name}:{grain}",
        }


def register(ctx) -> None:
    from hermes_constants import get_hermes_home

    guard = Guard(*_load(str(get_hermes_home())))
    ctx.register_hook("pre_llm_call", guard.pre_llm_call)
    ctx.register_hook("pre_tool_call", guard.pre_tool_call)
