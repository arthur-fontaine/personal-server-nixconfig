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

Plugins load long before there is anything to settle. ``hermes gateway``
starts plugin discovery on a background thread first thing
(hermes_cli/main.py, start_background_plugin_discovery), while the main thread
imports gateway.run; that import's config bridge waits for the discovery to
finish when config.yaml has an ``auxiliary`` section (gateway/run.py,
_bridge_auxiliary_config_to_env). So register() must not import gateway.run
(its module lock is held by a thread that waits for us: the load times out,
plugins.load_timeout_seconds, and Hermes drops every hook we registered), and
there is no runner yet anyway. register() returns at once and leaves the
boot to a thread that reads the runner from sys.modules, as Hermes' own tools
do (tools/cronjob_tools.py).

Then, at the pinned revision: GatewayRunner() publishes _gateway_runner_ref;
initialize_session_authority fences the lost turns ``unknown`` and publishes
runner.session_authority; start() sets runner._gateway_loop, connects
Telegram, and only then recover_gateway_native_sessions mounts and drains the
sessions with queued input (gateway/run_bootstrap.py, run_startup.py,
run_runtime.py). Two places settle the owner's turn:

- At boot, on the gateway's loop as soon as it has one: the turn settles in
  the store, the way Hermes settles an automation turn
  (settle_recovered_unattended), and the startup recovery drains what was
  queued. If the recovery mounted the session first (it leaves it paused on
  the unknown head, silently), the turn settles through the owner's own
  resolution (SessionAuthority.resolve_unknown_as_owner, the call /discard
  makes), which drains the queue.
- Before each of the owner's messages (``pre_gateway_dispatch``, awaited
  without a timeout on the gateway's loop, before admission:
  gateway/run_inbound.py): a turn lost while the gateway stayed up (a lost
  worker), or one the boot has not reached yet, settles the same way.

The pause notice is only ever the reply to a new message admitted onto the
unknown head (gateway/session_ingress.py, admit_message): with the hook in
front of every admission, the owner never gets it, however late the boot.

The messages the user steered into the lost turn (busy_input_mode steer,
agent/telegram.nix) are not queued: the recovery settles them with it,
``interrupted`` and never replayed (hermes_state_runtime.py,
recover_session_inputs). The notice quotes them, so Hermes answers them after
all.

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
import sys
import threading
import time
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
STEERED = "While it ran, you also sent these messages, which that turn may not have seen:"
QUOTE = 1000  # characters of each steered message the notice keeps
READY_WAIT = 900.0  # seconds a boot waits for the gateway before giving up
POLL = 0.05  # the boot's settlement window is seconds wide (Telegram connects in it)


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
            "SELECT admission_id, generation, target_session_id, principal_id, owner_epoch FROM session_admissions "
            "WHERE status='unknown' ORDER BY seq").fetchall()
    return [dict(zip(("admission_id", "generation", "target_session_id", "principal_id", "owner_epoch"), row))
            for row in rows if is_owner_dm(row[3], owner)]


def _text(payload: dict) -> str:
    # A native message keeps its text in its envelope (gateway/session_authority.py, _pending_receipt).
    text = payload.get("text")
    if text is None:
        text = payload.get("native_text_v1", {}).get("event", {}).get("text", "")
    return text if isinstance(text, str) else ""


def steered_into(db, row: dict) -> list[str]:
    """What was handed to the lost claim mid-turn: the admissions bound to its
    (owner_epoch, generation), settled with it (hermes_state_runtime.py, STEERING)."""
    with db._read_ctx() as conn:
        rows = conn.execute(
            "SELECT payload_json FROM session_admissions WHERE target_session_id=? AND owner_epoch=? "
            "AND generation=? AND admission_id!=? AND status='terminal' AND outcome IN ('steering','interrupted') "
            "ORDER BY seq", (row["target_session_id"], row["owner_epoch"], row["generation"],
                             row["admission_id"])).fetchall()
    texts = []
    for (payload,) in rows:
        try:
            text = _text(json.loads(payload)).strip()
        except (TypeError, ValueError, AttributeError):
            continue
        if text:
            texts.append(text[:QUOTE] + ("…" if len(text) > QUOTE else ""))
    return texts


def notice(db, row: dict) -> str:
    texts = steered_into(db, row)
    return "\n\n".join([NOTICE, STEERED, *(f"« {t} »" for t in texts)]) if texts else NOTICE


def has_queued(db, session_id: str) -> bool:
    with db._read_ctx() as conn:
        return conn.execute("SELECT 1 FROM session_admissions WHERE target_session_id=? "
                            "AND status IN ('queued','started','unknown') LIMIT 1", (session_id,)).fetchone() is not None


def _settle_in_store(db, epoch: int, row: dict, text: str = NOTICE) -> None:
    """No live session, so no drain to tell: settle_recovered_unattended's write."""
    from gateway.session_ingress_media import release_admission_media
    from gateway.session_results import close_discarded_turn
    from hermes_state_runtime import resolve_unknown_session_input
    resolve_unknown_session_input(
        db, epoch=epoch, admission_id=row["admission_id"], generation=row["generation"],
        _terminal_write=lambda conn, lost: close_discarded_turn(db, conn, lost, text))
    release_admission_media(db, row["admission_id"])


async def settle(authority, owner: Optional[str] = None) -> list[str]:
    """Settle the owner's lost turns; returns the sessions settled."""
    from gateway.session_contract import SessionRef
    from hermes_state_runtime import RuntimeStoreError
    owner = owner if owner is not None else owner_id()
    settled = []
    for row in await asyncio.to_thread(lost_owner_turns, authority.db, owner):
        session_id = row["target_session_id"]
        try:
            text = await asyncio.to_thread(notice, authority.db, row)
            if session_id in authority.sessions:
                await authority.resolve_unknown_as_owner(
                    SessionRef(authority.profile_id, session_id), row["admission_id"], row["generation"],
                    notice=text)
            else:
                await asyncio.to_thread(_settle_in_store, authority.db, authority.epoch, row, text)
        except RuntimeStoreError as exc:
            logger.warning("lost_turns: %s left unknown: %s", row["admission_id"], exc.reason)
            continue
        logger.info("lost_turns: the owner's turn %s on %s settled interrupted (not replayed)",
                    row["admission_id"], session_id)
        settled.append(session_id)
    return list(dict.fromkeys(settled))


def _runner():
    """The live GatewayRunner, never importing gateway.run: in the gateway it is
    still being imported while plugins load (see the module docstring); in any
    other process there is none."""
    ref = getattr(sys.modules.get("gateway.run"), "_gateway_runner_ref", None)
    try:
        return ref() if callable(ref) else None
    except Exception:
        return None


async def _poll(predicate, timeout: float, step: float = 1.0) -> bool:
    deadline = asyncio.get_running_loop().time() + timeout
    while not predicate():
        if asyncio.get_running_loop().time() >= deadline:
            return False
        await asyncio.sleep(step)
    return True


def _ready(runner) -> bool:
    return (getattr(runner, "session_runtime_descriptor", None) or {}).get("state") == "ready"


async def at_boot(ctx, runner, ready_wait: float = READY_WAIT) -> None:
    # Once per gateway: a plugin reload registers again.
    if getattr(runner, "_lost_turns_booted", False):
        return
    runner._lost_turns_booted = True
    authority = runner.session_authority
    settled = await settle(authority)
    if not settled:
        return
    idle = [sid for sid in settled if not await asyncio.to_thread(has_queued, authority.db, sid)]
    # Ready comes after the startup recovery, and after Telegram connected.
    if not await _poll(lambda: _ready(runner), ready_wait):
        logger.warning("lost_turns: the gateway never got ready; no continuation")
        return
    # The recovery may have read the head as unknown before the settlement
    # committed and mounted the session paused: wake it (a no-op while its
    # drain runs, or for a session not live).
    for session_id in settled:
        authority.wake_after_worker(session_id)
    # The continuation is a message in the owner's chat.
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


def _boot_ready(runner) -> Optional[asyncio.AbstractEventLoop]:
    loop = getattr(runner, "_gateway_loop", None)
    if getattr(runner, "session_authority", None) is None or loop is None or loop.is_closed():
        return None
    return loop


def watch_boot(ctx, wait: float = READY_WAIT, step: float = POLL) -> bool:
    """Wait for the runner, its fenced authority and its loop, then settle there.
    False when none came (the CLI, cron or a tool's process: no chat to settle)."""
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        runner = _runner()
        loop = _boot_ready(runner) if runner is not None else None
        if loop is not None:
            future = asyncio.run_coroutine_threadsafe(at_boot(ctx, runner), loop)
            future.add_done_callback(lambda f: f.cancelled() or not f.exception() or logger.warning(
                "lost_turns: boot settlement failed: %r", f.exception()))
            return True
        time.sleep(step)
    return False


def register(ctx) -> None:
    # Returns at once: Hermes runs register() under a deadline, beside a main
    # thread that is still importing gateway.run.
    ctx.register_hook("pre_gateway_dispatch", before_dispatch)
    threading.Thread(target=watch_boot, args=(ctx,), name="lost_turns-boot", daemon=True).start()
