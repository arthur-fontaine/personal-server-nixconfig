"""lost_turns: the owner's turn cut off by a gateway crash settles on its own.

When the gateway dies in the middle of a turn, the next one fences that turn
``unknown`` and pauses the chat's FIFO behind it: everything the user sends
next waits, and the pause notice asks them to send /discard
(gateway/session_ingress.py, pause_notice). Hermes does so on purpose for a
person's turn and settles only the turns nobody sent (cron, automation,
webhook: gateway/session_unattended_unknown.py, at the pinned revision). In
the owner's own DM, one person and one chat, that question is not worth a
stuck chat: the turn settles ``interrupted`` like /discard (never replayed),
with a notice in the transcript so Hermes knows it was cut off, and what was
queued behind it runs.

Two places, so the pause is never seen:

- At load, in ``GatewayRunner.start()``: the authority has already recovered
  the lost turns, but Telegram is not connected and no native session is live
  or drained yet (gateway/run_runtime.py, recover_gateway_native_sessions
  runs later). The turn settles in the store, the way Hermes settles an
  automation turn at boot (settle_recovered_unattended), and the startup
  recovery then drains what was queued.
- Before each of the owner's messages (``pre_gateway_dispatch``, awaited on
  the gateway's loop before admission): a turn lost while the gateway stayed
  up (a lost worker) settles through the owner's own resolution
  (SessionAuthority.resolve_unknown_as_owner, the call /discard makes).

When nothing was queued behind the lost turn, Hermes gets one turn of its own
once the gateway is ready (PluginContext.inject_message, an automation turn:
if it is lost too, Hermes settles it itself, so a turn that kills the gateway
is retried at most once). It starts with "[SYSTEM", which guard reads as not
the user's: its actions are reviewed as such.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
from typing import Any, Optional

logger = logging.getLogger(__name__)

# The transcript boundary that closes the lost turn (role assistant,
# display_kind failed_turn, sent to the model without its kind).
NOTICE = (
    "This turn was cut off: Hermes stopped before it finished and it was not run again. "
    "Some of its actions may already have run, so I check where that work stands before going on."
)
CONTINUE = (
    "[SYSTEM: Hermes restarted in the middle of your previous turn, which was cut off and not run "
    "again. Check where that work stands, then carry it on or tell the user where it stopped.]"
)
READY_WAIT = 900.0  # seconds a boot waits for the gateway before giving up the continuation


def owner_id() -> Optional[str]:
    # The owner's DM: its chat id is their user id, the first of
    # TELEGRAM_ALLOWED_USERS (as owner_approval reads it).
    first = os.environ.get("TELEGRAM_ALLOWED_USERS", "").split(",")[0].strip()
    return first if first.lstrip("-").isdigit() else None


def is_owner_dm(principal: str, owner: Optional[str]) -> bool:
    """A messaging principal is ``messaging:`` + [profile, platform, chat_id,
    thread_id, user_id] (gateway/session_authority.py, the native admission)."""
    if owner is None or not principal.startswith("messaging:"):
        return False
    try:
        _profile, platform, chat, thread, user = json.loads(principal[len("messaging:"):])
    except (ValueError, TypeError):
        return False
    return platform == "telegram" and thread is None and str(chat) == owner and str(user) == owner


def lost_owner_turns(db, owner: Optional[str]) -> list[dict]:
    with db._read_ctx() as conn:
        rows = conn.execute(
            "SELECT admission_id, generation, target_session_id, principal_id FROM session_admissions "
            "WHERE status='unknown' ORDER BY seq").fetchall()
    return [dict(zip(("admission_id", "generation", "target_session_id", "principal_id"), row))
            for row in rows if is_owner_dm(row[3], owner)]


def has_queued(db, session_id: str) -> bool:
    with db._read_ctx() as conn:
        return conn.execute("SELECT 1 FROM session_admissions WHERE target_session_id=? "
                            "AND status IN ('queued','started','unknown') LIMIT 1", (session_id,)).fetchone() is not None


def _settle_in_store(db, epoch: int, row: dict) -> None:
    """No live session, so no drain to tell: settle_recovered_unattended's write."""
    from gateway.session_ingress_media import release_admission_media
    from gateway.session_results import close_discarded_turn
    from hermes_state_runtime import resolve_unknown_session_input
    resolve_unknown_session_input(
        db, epoch=epoch, admission_id=row["admission_id"], generation=row["generation"],
        _terminal_write=lambda conn, lost: close_discarded_turn(db, conn, lost, NOTICE))
    release_admission_media(db, row["admission_id"])


async def settle(authority, owner: Optional[str] = None) -> list[str]:
    """Settle the owner's lost turns; returns the sessions that have nothing left to run."""
    from gateway.session_contract import SessionRef
    from hermes_state_runtime import RuntimeStoreError
    owner = owner if owner is not None else owner_id()
    settled = []
    for row in await asyncio.to_thread(lost_owner_turns, authority.db, owner):
        session_id = row["target_session_id"]
        try:
            if session_id in authority.sessions:
                await authority.resolve_unknown_as_owner(
                    SessionRef(authority.profile_id, session_id), row["admission_id"], row["generation"],
                    notice=NOTICE)
            else:
                await asyncio.to_thread(_settle_in_store, authority.db, authority.epoch, row)
        except RuntimeStoreError as exc:
            logger.warning("lost_turns: %s left unknown: %s", row["admission_id"], exc.reason)
            continue
        logger.info("lost_turns: the owner's turn %s on %s settled interrupted (not replayed)",
                    row["admission_id"], session_id)
        settled.append(session_id)
    idle = []
    for session_id in dict.fromkeys(settled):
        if not await asyncio.to_thread(has_queued, authority.db, session_id):
            idle.append(session_id)
    return idle


def _runner():
    try:
        from gateway.run import _gateway_runner_ref
        return _gateway_runner_ref() if _gateway_runner_ref else None
    except Exception:
        return None


async def _poll(predicate, timeout: float, step: float = 1.0) -> bool:
    deadline = asyncio.get_running_loop().time() + timeout
    while not predicate():
        if asyncio.get_running_loop().time() >= deadline:
            return False
        await asyncio.sleep(step)
    return True


async def at_boot(ctx, runner, ready_wait: float = READY_WAIT) -> None:
    if not await _poll(lambda: getattr(runner, "session_authority", None) is not None, ready_wait):
        return
    authority = runner.session_authority
    idle = await settle(authority)
    if not idle:
        return
    # The continuation is a message in the owner's chat: only once Telegram
    # is connected and the startup recovery ran.
    descriptor = lambda: getattr(runner, "session_runtime_descriptor", None) or {}
    if not await _poll(lambda: descriptor().get("state") == "ready", ready_wait):
        logger.warning("lost_turns: the gateway never got ready; no continuation")
        return
    owner = owner_id()
    for session_id in idle:
        # The user wrote in the meantime: their message runs, after the notice.
        if await asyncio.to_thread(has_queued, authority.db, session_id):
            continue
        origin = {"platform": "telegram", "chat_id": owner, "chat_type": "dm", "user_id": owner}
        if not ctx.inject_message(CONTINUE, origin=origin):
            logger.warning("lost_turns: could not continue %s", session_id)


def _owner_message(event) -> bool:
    source = getattr(event, "source", None)
    platform = getattr(getattr(source, "platform", None), "value", getattr(source, "platform", None))
    owner = owner_id()
    return (platform == "telegram" and owner is not None and str(getattr(source, "chat_id", "")) == owner
            and str(getattr(source, "user_id", "")) == owner)


async def before_dispatch(event=None, gateway=None, **_) -> None:
    if not _owner_message(event):
        return None
    authority = getattr(gateway, "session_authority", None)
    if authority is None:
        return None
    try:
        await settle(authority)
    except Exception:
        # Never in the way of the message: at worst the chat pauses as before.
        logger.warning("lost_turns: settling before a message failed", exc_info=True)
    return None


_TASKS: set = set()


def register(ctx) -> None:
    ctx.register_hook("pre_gateway_dispatch", before_dispatch)
    runner = _runner()
    if runner is None:
        return  # the CLI, cron or a tool's process: no chat to settle
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        loop = getattr(runner, "_gateway_loop", None)
    if loop is None or loop.is_closed():
        return
    future = asyncio.run_coroutine_threadsafe(at_boot(ctx, runner), loop)
    _TASKS.add(future)
    future.add_done_callback(_TASKS.discard)
    future.add_done_callback(lambda f: f.cancelled() or not f.exception() or logger.warning(
        "lost_turns: boot settlement failed: %r", f.exception()))
