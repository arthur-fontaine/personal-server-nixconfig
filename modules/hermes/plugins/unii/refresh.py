"""New instructions reach the chat that never ends.

Hermes keeps a session's system prompt and its tool list from the session's
first turn, and rebuilds them only when the model, the provider or the working
directory change (agent/conversation_loop.py, _restore_or_build_system_prompt,
at https://github.com/NousResearch/hermes-agent/blob/74885f997bece88c1393bd174b25b32338336cb6/agent/conversation_loop.py).
unii's chat is one session that never ends, so a new AGENTS.md, SOUL.md or
toolset never reached it. When those files change, every open session's stored
prompt and tool list are dropped, once: Hermes builds both again on its next
turn, as for a stored prompt that is missing.
"""

from __future__ import annotations

import hashlib
import logging
import os
from typing import Callable

logger = logging.getLogger(__name__)


def fingerprint(paths: list[str]) -> str:
    digest = hashlib.sha256()
    for path in paths:
        digest.update(path.encode() + b"\0")
        try:
            with open(path, "rb") as f:
                digest.update(f.read())
        except OSError:
            digest.update(b"(missing)")
        digest.update(b"\0")
    return digest.hexdigest()


def refresh_prompts(home: str, workspace: str, session_db: Callable) -> int:
    """Drop the open sessions' stored prompts and tool lists when the
    instructions changed since the last run. Returns how many it reset."""
    paths = [os.path.join(home, "SOUL.md"), os.path.join(home, "config.yaml")]
    if workspace:
        paths.append(os.path.join(workspace, "AGENTS.md"))
    stamp = os.path.join(home, "unii", "instructions.sha256")
    current = fingerprint(paths)
    try:
        with open(stamp) as f:
            if f.read().strip() == current:
                return 0
    except OSError:
        pass

    db = session_db()
    reset = 0
    try:
        rows = db.list_sessions_rich(
            limit=100_000, include_children=True, include_archived=True, include_hidden=True,
            include_subagents=True, project_compression_tips=False,
        )
        for row in rows:
            if row.get("ended_at"):
                continue
            db.update_system_prompt(row["id"], None)
            db.update_session_tool_names(row["id"], None)
            reset += 1
    finally:
        db.close()

    # Written only once every session is reset: a failure retries next start.
    os.makedirs(os.path.dirname(stamp), mode=0o700, exist_ok=True)
    tmp = stamp + ".tmp"
    with open(tmp, "w") as f:
        f.write(current + "\n")
    os.replace(tmp, stamp)
    logger.info("unii: instructions changed, %d open session(s) rebuild their prompt", reset)
    return reset
