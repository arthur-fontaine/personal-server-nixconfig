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

``tell(text)`` sends the owner a plain message, without buttons or waiting.

The result is one of the given ids, ``"timeout"`` (no tap in time, or the
gateway stopping) or ``"unavailable"`` (no gateway in this process, Telegram
not connected, no owner configured, the message could not be sent). Both are
in ``DENIALS``: whatever is not one of your ids must refuse. Ids are short
strings without ":" (at most 16 characters, Telegram caps a button's
callback_data at 64 bytes); labels are what the buttons show.

The plugin also gives Hermes a tool, ``propose`` (toolset ``owner_proposal``),
for a turn that is not the main chat (the events daemon's): it posts a
proposal there with one button per option, and mirrors it into the main
chat's session; a tap by the owner continues the main chat with "I picked
…" as their turn (PluginContext.inject_message, which needs
plugins.entries.owner_approval.allow_gateway_injection).

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
import json
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
class _Proposal:
    options: list[str]
    text: str
    chat_id: int
    message_id: Optional[int] = None


@dataclass
class _State:
    app: Any = None
    adapter: Any = None
    ctx: Any = None
    loop: Optional[asyncio.AbstractEventLoop] = None
    pending: dict[str, _Pending] = field(default_factory=dict)
    proposals: dict[str, _Proposal] = field(default_factory=dict)
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
    # Never an import: outside the gateway it would load the whole gateway, and
    # in it, before startup ends, gateway.run may still be importing on a thread
    # that waits for us (lost_turns' docstring). Hermes reads it the same way
    # (tools/cronjob_tools.py).
    ref = getattr(sys.modules.get("gateway.run"), "_gateway_runner_ref", None)
    try:
        runner = ref() if callable(ref) else None
    except Exception:
        runner = None
    loop = getattr(runner, "_gateway_loop", None) or STATE.loop
    if loop is None or loop.is_closed() or not loop.is_running():
        return None
    return loop


def _app(name: str, *args) -> None:
    """Tell the app_topic plugin (the owner's iOS app), when loaded, about a
    question it cannot see: these go through the bot, not Hermes' adapter."""
    fn = getattr(sys.modules.get("app_topic"), name, None)
    if fn is not None:
        try:
            fn(*args)
        except Exception:
            logger.debug("owner_approval: app_topic.%s failed", name, exc_info=True)


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
        _app("question_card", target, None, pending.message_id, text, InlineKeyboardMarkup(rows), details)
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
        if pending.message_id is not None:
            _app("question_done", target, pending.message_id)


async def _edit(pending, outcome: str) -> None:
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
    data = str(getattr(query, "data", None) or "")
    if not data.startswith((PREFIX, PROPOSAL_PREFIX)):
        return
    owner = owner_id()
    if owner is None or getattr(query.from_user, "id", None) != owner:
        await query.answer(text="Only the owner can answer this.")
        return
    if data.startswith(PROPOSAL_PREFIX):
        await _on_proposal(query, data)
        return
    request, _, index = data[len(PREFIX):].partition(":")
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


PROPOSAL_PREFIX = "op:"
MAX_PROPOSALS = 50
PROPOSE_SCHEMA = {
    "name": "propose",
    "description": (
        "Post a proposal to the user in their main Telegram chat, with one button per option, from a "
        "turn that is not that chat (an event). Their tap continues the main chat, where all your "
        "tools are. In the main chat itself, ask with clarify instead."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "message": {"type": "string", "description": "The proposal, as the user reads it."},
            "options": {
                "type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 4,
                "description": "What you could do, each a short self-contained action (it becomes the user's "
                               "answer when tapped), e.g. \"Reply to Léa that I'm in for 8pm\".",
            },
        },
        "required": ["message", "options"],
    },
}


def _mirror(chat_id: int, text: str) -> None:
    # As the webhook route's mirror_to_session does (gateway/platforms/webhook.py,
    # _mirror_delivery): a user-role note, so a typed answer has the context too.
    try:
        from gateway.mirror import mirror_to_session

        mirror_to_session("telegram", str(chat_id), text, source_label="webhook", role="user")
    except Exception as error:
        logger.info("owner_approval: proposal not mirrored: %s", error)


async def _propose_on_loop(message: str, options: list[str]) -> str:
    bot, owner = _bot(), owner_id()
    if bot is None or owner is None:
        return "Telegram is not connected"
    from telegram import InlineKeyboardButton, InlineKeyboardMarkup

    key = secrets.token_hex(4)
    listing = "\n".join(f"{n + 1}. {option}" for n, option in enumerate(options))
    text = _render("Proposal", f"{message}\n\n{listing}").split("\n\n", 1)[1]
    rows = [[InlineKeyboardButton(f"{n + 1}. {option}"[:60], callback_data=f"{PROPOSAL_PREFIX}{key}:{n}")]
            for n, option in enumerate(options)]
    proposal = _Proposal(options, text, owner)
    try:
        sent = await bot.send_message(chat_id=owner, text=text, parse_mode="HTML",
                                      reply_markup=InlineKeyboardMarkup(rows))
    except Exception as error:
        return f"send failed: {error}"
    proposal.message_id = getattr(sent, "message_id", None)
    _app("question_card", owner, None, proposal.message_id, text, InlineKeyboardMarkup(rows))
    with STATE.lock:
        STATE.proposals[key] = proposal
        while len(STATE.proposals) > MAX_PROPOSALS:
            STATE.proposals.pop(next(iter(STATE.proposals)))
    return ""


def propose(args: dict, **_) -> str:
    message = str((args or {}).get("message") or "").strip()
    options = [str(o).strip() for o in (args or {}).get("options") or [] if str(o).strip()][:4]
    if not message or not options:
        return json.dumps({"error": "message and options are required"})
    loop = _gateway_loop()
    if loop is None:
        error = "no gateway"
    else:
        try:
            error = asyncio.run_coroutine_threadsafe(_propose_on_loop(message, options), loop).result(30)
        except Exception as exc:
            error = str(exc) or type(exc).__name__
    if error:
        return json.dumps({"error": f"not sent ({error}): write the proposal as your answer instead"})
    listing = "\n".join(f"{n + 1}. {option}" for n, option in enumerate(options))
    _mirror(owner_id(), f"[Proposal with buttons]\n{message}\n\n{listing}")
    return json.dumps({"sent": True, "note": "The user has it, with buttons: answer exactly [SILENT]."})


async def _on_proposal(query, data: str) -> None:
    key, _, index = data[len(PROPOSAL_PREFIX):].partition(":")
    with STATE.lock:
        proposal = STATE.proposals.pop(key, None)
    try:
        option = proposal.options[int(index)] if proposal else None
    except (ValueError, IndexError):
        option = None
    if option is None:
        await query.answer(text="Expired: answer in the chat.")
        try:
            await query.edit_message_reply_markup(reply_markup=None)
        except Exception:
            pass
        return
    ctx = STATE.ctx
    owner = owner_id()
    origin = {"platform": "telegram", "chat_id": str(owner), "chat_type": "dm", "user_id": str(owner)}
    # Not starting with "[": the user chose this, and guard must read it as their turn.
    turn = f"I picked option {int(index) + 1} of your proposal: {option}"
    ok = False
    if ctx is not None:
        try:
            ok = bool(ctx.inject_message(turn, origin=origin))
        except Exception as error:
            logger.warning("owner_approval: could not continue the main chat: %s", error)
    await query.answer(text=option[:190] if ok else "Could not reach the chat: answer by text.")
    outcome = (f"→ <b>{html.escape(option)}</b>" if ok
               else "<i>Could not reach the main chat: answer by text.</i>")
    await _edit(proposal, outcome)


def tell(text: str) -> bool:
    """A plain message to the owner's main chat, without waiting (callable from
    any thread but the gateway loop's own, where it would not be sent before
    the caller returns): whether it was handed to the bot."""
    bot, owner, loop = _bot(), owner_id(), _gateway_loop()
    if bot is None or owner is None or loop is None:
        return False

    async def send() -> None:
        try:
            await bot.send_message(chat_id=owner, text=text[:4000])
        except Exception as error:
            logger.warning("owner_approval: message not sent: %s", error)

    asyncio.run_coroutine_threadsafe(send(), loop)
    return True


def telegram_handlers(app, adapter) -> None:
    from telegram.ext import CallbackQueryHandler

    STATE.app, STATE.adapter = app, adapter
    try:
        STATE.loop = asyncio.get_running_loop()
    except RuntimeError:
        pass
    app.add_handler(CallbackQueryHandler(on_callback, pattern=r"^o[ap]:"))


def no_reply_expected(event=None, **_) -> None:
    """An event run speaks through `propose`, then answers [SILENT]. The webhook
    adapter leaves `reply_expected` unset, and the gateway then replaces a bare
    silence with "The model returned only a silence marker…" (gateway/
    response_filters.py `silence_allowed`, hermes-agent 74885f9). A webhook
    delivery has no one waiting for an answer: say so before it is admitted,
    which persists the field with the turn."""
    source = getattr(event, "source", None)
    platform = getattr(source, "platform", None)
    if getattr(platform, "value", platform) == "webhook":
        event.reply_expected = False
    return None


def register(ctx) -> None:
    # One module, one state: other plugins import it by this name.
    sys.modules.setdefault("owner_approval", sys.modules[__name__])
    STATE.ctx = ctx
    ctx.register_telegram_handler(telegram_handlers)
    ctx.register_tool(name="propose", toolset="owner_proposal", schema=PROPOSE_SCHEMA, handler=propose)
    ctx.register_hook("pre_gateway_dispatch", no_reply_expected)
