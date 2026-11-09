"""owner_approval against a fake gateway loop and a fake Telegram bot."""

from __future__ import annotations

import asyncio
import json
import os
import sys
import threading
import time
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import owner_approval as oa  # noqa: E402

OWNER = 4242


class Bot:
    def __init__(self) -> None:
        self.sent: list[dict] = []
        self.edits: list[dict] = []
        self.fail = False

    async def send_message(self, **kwargs):
        if self.fail:
            raise RuntimeError("Bad Request: chat not found")
        self.sent.append(kwargs)
        return types.SimpleNamespace(message_id=len(self.sent))

    async def edit_message_text(self, **kwargs):
        self.edits.append(kwargs)


class App:
    def __init__(self, bot) -> None:
        self.bot, self.handlers = bot, []

    def add_handler(self, handler, group=0) -> None:
        self.handlers.append(handler)


class Query:
    def __init__(self, data: str, user: int) -> None:
        self.data, self.from_user = data, types.SimpleNamespace(id=user, first_name="Arthur")
        self.answers: list[str] = []

    async def answer(self, text=None):
        self.answers.append(text)

    async def edit_message_reply_markup(self, reply_markup=None):
        pass


def wait_for(predicate, what: str, timeout: float = 10) -> None:
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError(f"timed out waiting for {what}")
        time.sleep(0.01)


def main() -> None:
    os.environ["TELEGRAM_ALLOWED_USERS"] = f"{OWNER},77"
    loop = asyncio.new_event_loop()
    threading.Thread(target=loop.run_forever, daemon=True).start()
    run = lambda coro: asyncio.run_coroutine_threadsafe(coro, loop).result(10)  # noqa: E731
    choices = [("once", "Once"), ("host", "pypi.org for this session"), ("deny", "Deny")]

    # No gateway, no Telegram: refuse without asking.
    assert oa.ask("Network", "GET https://pypi.org/", choices, timeout=1) == oa.UNAVAILABLE

    # The plugin registers one scoped handler and publishes its module.
    registered, tools, injected, hooks = [], {}, [], {}
    ctx = types.SimpleNamespace(
        register_telegram_handler=registered.append,
        register_tool=lambda **kw: tools.__setitem__(kw["name"], kw),
        register_hook=hooks.__setitem__,
        inject_message=lambda content, **kw: injected.append((content, kw)) or True)
    oa.register(ctx)
    assert sys.modules["owner_approval"] is oa and registered == [oa.telegram_handlers]
    assert tools["propose"]["toolset"] == "owner_proposal"

    # A webhook delivery (an event's run) may end in [SILENT]; a chat message still expects a reply.
    from gateway.config import Platform
    from gateway.platforms.base import MessageEvent
    from gateway.session import SessionSource

    def event(platform):
        return MessageEvent(text="x", source=SessionSource(platform=platform, chat_id="1"))

    webhook, telegram = event(Platform.WEBHOOK), event(Platform.TELEGRAM)
    for e in (webhook, telegram):
        assert hooks["pre_gateway_dispatch"](event=e, gateway=None, session_store=None) is None
    assert webhook.reply_expected is False and telegram.reply_expected is None
    from gateway.response_filters import silence_allowed
    assert silence_allowed(None, webhook.reply_expected)
    assert "error" in json.loads(tools["propose"]["handler"]({"message": "x", "options": ["a"]}))
    bot = Bot()
    app = App(bot)

    async def wire():
        oa.telegram_handlers(app, types.SimpleNamespace(_bot=bot))

    run(wire())
    (handler,) = app.handlers
    assert handler.pattern.match("oa:abcd1234:0") and not handler.pattern.match("ea:once:1")
    assert not handler.pattern.match("cl:1:0") and handler.pattern.match("op:abcd1234:1")

    def tap(index: int, user: int, n: int = -1) -> Query:
        data = bot.sent[n]["reply_markup"].inline_keyboard
        button = [b for row in data for b in row][index]
        assert len(button.callback_data.encode()) <= 64
        query = Query(button.callback_data, user)
        run(oa.on_callback(types.SimpleNamespace(callback_query=query)))
        return query

    # A stranger's tap does nothing; the owner's answers, and the message says so.
    result: list[str] = []
    thread = threading.Thread(target=lambda: result.append(oa.ask(
        "Network access", "Pi wants GET https://pypi.org/simple/ <&>", choices, timeout=30)))
    thread.start()
    wait_for(lambda: bot.sent, "the question")
    message = bot.sent[-1]
    assert message["chat_id"] == OWNER and message["parse_mode"] == "HTML"
    assert "<b>Network access</b>" in message["text"] and "&lt;&amp;&gt;" in message["text"]
    assert [b.text for row in message["reply_markup"].inline_keyboard for b in row] == [l for _, l in choices]
    stranger = tap(1, 77)
    assert stranger.answers == ["Only the owner can answer this."] and not result
    tap(1, OWNER)
    thread.join(10)
    assert result == ["host"], result
    assert "pypi.org for this session" in bot.edits[-1]["text"] and bot.edits[-1]["reply_markup"] is None

    # No answer in time: refused, and the message says so; a late tap is told.
    assert oa.ask("Shell", "rm -rf build", choices, timeout=0.2) == oa.TIMEOUT
    assert "No answer" in bot.edits[-1]["text"]
    late = tap(0, OWNER)
    assert late.answers == ["Already answered or expired."]

    # From a coroutine on another loop, and to another chat.
    async def other():
        return await oa.ask_async("Push", "git push origin feature", choices, timeout=30, chat_id=-100123)

    other_result: list[str] = []
    thread = threading.Thread(target=lambda: other_result.append(asyncio.run(other())))
    thread.start()
    wait_for(lambda: len(bot.sent) == 3, "the third question")
    assert bot.sent[-1]["chat_id"] == -100123
    tap(2, OWNER)
    thread.join(10)
    assert other_result == ["deny"]

    # Blocking on the gateway loop itself would deadlock: refused at once.
    async def on_loop():
        return oa.ask("x", "y", choices, timeout=5)

    assert run(on_loop()) == oa.UNAVAILABLE

    # Long details still fit one Telegram message.
    thread = threading.Thread(target=lambda: oa.ask("Long", "&" * 20000, choices, timeout=0.2))
    thread.start()
    thread.join(10)
    assert len(bot.sent[-1]["text"]) < 4096 and len(bot.edits[-1]["text"]) < 4096

    # A failed send, or no owner configured: unavailable, never a yes.
    bot.fail = True
    assert oa.ask("x", "y", choices, timeout=5) == oa.UNAVAILABLE
    bot.fail = False
    os.environ["TELEGRAM_ALLOWED_USERS"] = ""
    assert oa.ask("x", "y", choices, timeout=5) == oa.UNAVAILABLE
    os.environ["TELEGRAM_ALLOWED_USERS"] = str(OWNER)

    # A plain message to the owner, from any thread, without waiting.
    count = len(bot.sent)
    assert oa.tell("Auto mode can't reach its review model")
    wait_for(lambda: len(bot.sent) == count + 1, "the message")
    assert bot.sent[-1]["chat_id"] == OWNER and "reply_markup" not in bot.sent[-1]

    # An event's proposal: buttons in the main chat; the owner's tap continues it.
    out = json.loads(tools["propose"]["handler"]({
        "message": "Léa invites you for drinks at 8pm; you are free.",
        "options": ["Reply to Léa that I'm in for 8pm", "Ask Léa where", "Ignore"]}))
    assert out["sent"] and "[SILENT]" in out["note"], out
    message = bot.sent[-1]
    assert message["chat_id"] == OWNER and "1. Reply to Léa" in message["text"]
    assert tap(1, 77).answers == ["Only the owner can answer this."] and not injected
    tap(0, OWNER)
    ((turn, kw),) = injected
    assert turn == "I picked option 1 of your proposal: Reply to Léa that I'm in for 8pm"
    assert kw["origin"] == {"platform": "telegram", "chat_id": str(OWNER), "chat_type": "dm", "user_id": str(OWNER)}
    assert "Reply to Léa" in bot.edits[-1]["text"] and bot.edits[-1]["reply_markup"] is None
    # guard reads that turn as the user's: it is not one of the gateway's notices.
    import guard

    assert not guard.internal(turn)
    assert tap(1, OWNER).answers == ["Expired: answer in the chat."] and len(injected) == 1

    # Ids the result could be confused with are refused.
    for bad in ([], [("timeout", "x")], [("a:b", "x")]):
        try:
            oa.ask("x", "y", bad)
        except ValueError:
            pass
        else:
            raise AssertionError(bad)

    loop.call_soon_threadsafe(loop.stop)
    print("owner_approval: ok")


if __name__ == "__main__":
    main()
