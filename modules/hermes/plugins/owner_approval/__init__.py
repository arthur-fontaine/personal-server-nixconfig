"""owner_approval: ask the owner a question with Telegram buttons, outside any turn.

Hermes' own prompts (the approval card, clarify) belong to a turn: they post in
the chat the turn runs in and resolve that turn's pending entry. This asks
the owner from anywhere in the gateway's process (a plugin's thread, a
background task, a sidecar's callback) and waits for their tap.

Python API (other plugins import it lazily, at call time, once this plugin is
loaded; ``register`` publishes this module as ``owner_approval``)::

    from owner_approval import ask, ask_async, DENIALS

    # From a worker thread (never the gateway's event loop): blocks.
    choice = ask(
        "Network access",                       # title, bold
        "Pi (sandbox s1) wants GET https://pypi.org/simple/",  # details, as is
        [("once", "Once"), ("host", "pypi.org for this session"), ("deny", "Deny")],
        timeout=300,                            # seconds; no answer = "timeout"
    )
    if choice in ("once", "host"): ...         # anything else is a refusal

    # From a coroutine, on any event loop:
    choice = await ask_async(title, details, choices, timeout=300)

The result is one of the given ids, ``"timeout"`` (no tap in time, or the
gateway stopping) or ``"unavailable"`` (no gateway in this process, Telegram
not connected, no owner configured, the message could not be sent). Both are
in ``DENIALS``: whatever is not one of your ids must refuse. Ids are short
strings without ":" (at most 16 characters, Telegram caps a button's
callback_data at 64 bytes); labels are what the buttons show.

The question goes to the main chat (the owner's DM with the bot: its chat id
is their user id, the first of TELEGRAM_ALLOWED_USERS), or to ``chat_id`` if
given. Only the owner's taps count, wherever the message is. Once answered,
or timed out, the message is edited to say what happened and loses its
buttons. Callbacks are ``oa:<request>:<index>``, a prefix Hermes' core
handlers do not use (plugins/platforms/telegram/adapter.py,
_handle_callback_query), scoped with ``pattern=`` as register_telegram_handler
requires.
"""

from __future__ import annotations

import asyncio
import html
import logging
import os
import secrets
import sys
import threading
from dataclasses import dataclass, field
from typing import Any, Optional

logger = logging.getLogger(__name__)

PREFIX = "oa:"
TIMEOUT = "timeout"
UNAVAILABLE = "unavailable"
DENIALS = frozenset({TIMEOUT, UNAVAILABLE})
# Telegram's cap is 4096 characters; the title, the outcome and the HTML
# escaping take the rest.
MAX_DETAILS = 3000


@dataclass
class _Pending:
    future: asyncio.Future
    choices: list[tuple[str, str]]
    text: str
    chat_id: int
    message_id: Optional[int] = None


@dataclass
class _State:
    app: Any = None
    adapter: Any = None
    loop: Optional[asyncio.AbstractEventLoop] = None
    pending: dict[str, _Pending] = field(default_factory=dict)
    lock: threading.Lock = field(default_factory=threading.Lock)


STATE = _State()


def owner_id() -> Optional[int]:
    first = os.environ.get("TELEGRAM_ALLOWED_USERS", "").split(",")[0].strip()
    return int(first) if first.lstrip("-").isdigit() else None


def _bot():
    adapter, app = STATE.adapter, STATE.app
    # The adapter's own bot is the live one after a reconnect rebuilt the app.
    return getattr(adapter, "_bot", None) or getattr(app, "bot", None)


def _gateway_loop() -> Optional[asyncio.AbstractEventLoop]:
    try:
        from gateway.run import _gateway_runner_ref

        runner = _gateway_runner_ref()
    except Exception:
        runner = None
    loop = getattr(runner, "_gateway_loop", None) or STATE.loop
    if loop is None or loop.is_closed() or not loop.is_running():
        return None
    return loop


def _render(title: str, details: str) -> str:
    # Cut before escaping, so no entity is split, until the escaped text fits.
    title, body, cut = html.escape(title[:200]), html.escape(details), len(details)
    while len(body) > MAX_DETAILS:
        cut = cut * MAX_DETAILS // len(body) - 1
        body = html.escape(details[:cut]) + "…"
    return f"<b>{title}</b>\n\n{body}"


def _validate(choices) -> list[tuple[str, str]]:
    out = [(str(i), str(label)) for i, label in choices]
    if not out:
        raise ValueError("owner_approval: no choices")
    for i, _ in out:
        if not i or ":" in i or len(i) > 16 or i in DENIALS:
            raise ValueError(f"owner_approval: bad choice id {i!r}")
    return out


async def _ask_on_loop(title, details, choices, timeout, chat_id) -> str:
    bot, owner = _bot(), owner_id()
    if bot is None or owner is None:
        logger.warning("owner_approval: cannot ask (%s)", "Telegram not connected" if bot is None else "no owner")
        return UNAVAILABLE
    from telegram import InlineKeyboardButton, InlineKeyboardMarkup

    request = secrets.token_hex(4)
    buttons = [InlineKeyboardButton(label, callback_data=f"{PREFIX}{request}:{n}") for n, (_, label) in enumerate(choices)]
    rows = [buttons[n:n + 2] for n in range(0, len(buttons), 2)]
    text = _render(title, details)
    target = int(chat_id) if chat_id is not None else owner
    pending = _Pending(asyncio.get_running_loop().create_future(), choices, text, target)
    with STATE.lock:
        STATE.pending[request] = pending
    try:
        try:
            message = await bot.send_message(
                chat_id=target, text=text, parse_mode="HTML", reply_markup=InlineKeyboardMarkup(rows))
        except Exception as error:
            logger.warning("owner_approval: send failed: %s", error)
            return UNAVAILABLE
        pending.message_id = getattr(message, "message_id", None)
        try:
            return await asyncio.wait_for(asyncio.shield(pending.future), timeout)
        except (asyncio.TimeoutError, asyncio.CancelledError) as error:
            minutes = max(1, round(timeout / 60))
            await _edit(pending, f"⏱ <i>No answer in {minutes} min: refused.</i>")
            if isinstance(error, asyncio.CancelledError):
                raise
            return TIMEOUT
    finally:
        with STATE.lock:
            STATE.pending.pop(request, None)


async def _edit(pending: _Pending, outcome: str) -> None:
    bot = _bot()
    if bot is None or pending.message_id is None:
        return
    try:
        await bot.edit_message_text(
            chat_id=pending.chat_id, message_id=pending.message_id,
            text=f"{pending.text}\n\n{outcome}", parse_mode="HTML", reply_markup=None)
    except Exception as error:
        logger.info("owner_approval: could not edit the question: %s", error)


async def ask_async(title: str, details: str, choices, timeout: float = 300, chat_id=None) -> str:
    """Ask the owner; see the module docstring. Never raises for a missing
    gateway: returns "unavailable"."""
    choices = _validate(choices)
    loop = _gateway_loop()
    if loop is None:
        logger.warning("owner_approval: no gateway loop: cannot ask %r", title)
        return UNAVAILABLE
    coro = _ask_on_loop(title, details, choices, timeout, chat_id)
    if asyncio.get_running_loop() is loop:
        return await coro
    return await asyncio.wrap_future(asyncio.run_coroutine_threadsafe(coro, loop))


def ask(title: str, details: str, choices, timeout: float = 300, chat_id=None) -> str:
    """Blocking ask_async, for a thread that is not the gateway's loop."""
    choices = _validate(choices)
    loop = _gateway_loop()
    if loop is None:
        logger.warning("owner_approval: no gateway loop: cannot ask %r", title)
        return UNAVAILABLE
    try:
        running = asyncio.get_running_loop()
    except RuntimeError:
        running = None
    if running is loop:
        # Blocking here would block the very loop that receives the tap.
        logger.error("owner_approval: ask() called on the gateway loop; use ask_async")
        return UNAVAILABLE
    future = asyncio.run_coroutine_threadsafe(_ask_on_loop(title, details, choices, timeout, chat_id), loop)
    try:
        return future.result(timeout + 30)
    except Exception as error:
        future.cancel()
        logger.warning("owner_approval: %r ended without an answer: %s", title, error)
        return TIMEOUT


async def on_callback(update, context=None) -> None:
    query = getattr(update, "callback_query", None)
    if query is None or not str(query.data or "").startswith(PREFIX):
        return
    owner = owner_id()
    if owner is None or getattr(query.from_user, "id", None) != owner:
        await query.answer(text="Only the owner can answer this.")
        return
    request, _, index = query.data[len(PREFIX):].partition(":")
    with STATE.lock:
        pending = STATE.pending.get(request)
    if pending is None or pending.future.done():
        await query.answer(text="Already answered or expired.")
        try:
            await query.edit_message_reply_markup(reply_markup=None)
        except Exception:
            pass
        return
    try:
        choice, label = pending.choices[int(index)]
    except (ValueError, IndexError):
        await query.answer(text="Unknown choice.")
        return
    pending.future.set_result(choice)
    await query.answer(text=label[:190])
    who = html.escape(getattr(query.from_user, "first_name", None) or "the owner")
    await _edit(pending, f"→ <b>{html.escape(label)}</b> <i>({who})</i>")


def telegram_handlers(app, adapter) -> None:
    from telegram.ext import CallbackQueryHandler

    STATE.app, STATE.adapter = app, adapter
    try:
        STATE.loop = asyncio.get_running_loop()
    except RuntimeError:
        pass
    app.add_handler(CallbackQueryHandler(on_callback, pattern=r"^oa:"))


def register(ctx) -> None:
    # One module, one state: other plugins import it by this name.
    sys.modules.setdefault("owner_approval", sys.modules[__name__])
    ctx.register_telegram_handler(telegram_handlers)
