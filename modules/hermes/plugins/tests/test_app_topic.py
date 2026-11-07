"""app_topic against a fake Telegram bot and adapter, on a real event loop."""

from __future__ import annotations

import asyncio
import base64
import json
import os
import struct
import sys
import tempfile
import threading
import time
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

TMP = tempfile.mkdtemp(prefix="app-topic-test-")
os.environ["HERMES_HOME"] = os.path.join(TMP, "hermes")
os.environ["TELEGRAM_ALLOWED_USERS"] = "4242"
os.makedirs(os.environ["HERMES_HOME"], exist_ok=True)

from app_topic import app as app_mod  # noqa: E402
from app_topic import bigfiles, call, machine, protocol, questions, speech, usage  # noqa: E402
from app_topic.pet import Needs, level_for, xp_for_level  # noqa: E402
from app_topic.status import Status, tool_label  # noqa: E402

OWNER = 4242
app_mod.SEND_GAP = 0.01
app_mod.SLOT_MIN_GAP = 0.05
app_mod.SETTLE = 0.2


def wait_for(predicate, what: str, timeout: float = 10) -> None:
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError(f"timed out waiting for {what}")
        time.sleep(0.02)


# ── pure parts ───────────────────────────────────────────────────────────

def test_protocol() -> None:
    assert protocol.parse('{"v":1,"type":"pet.feed"}') == {"v": 1, "type": "pet.feed"}
    assert protocol.parse('```json\n{"v":1,"type":"hello"}\n```')["type"] == "hello"
    assert protocol.parse("hello there") is None and protocol.parse('{"no":"type"}') is None
    html = protocol.render_html({"a": "<b>&"})
    assert html.startswith('<pre><code class="language-json">') and "&lt;b&gt;&amp;" in html
    big = protocol.message("stats", models=[{"name": "x" * 100} for _ in range(100)])
    small = protocol.shrink(big, [("models",)])
    assert protocol.fits(small) and small["truncated"] and 0 < len(small["models"]) < 100
    assert protocol.utf16_len("😀") == 2


def test_speech() -> None:
    text = "**Done** ✅ — 3 files changed → see https://github.com/a/b/pull/7. Next: `nix build`.\nMore later."
    spoken = speech.spoken(text)
    assert "**" not in spoken and "https" not in spoken and "✅" not in spoken
    assert "a link to github.com" in spoken and " to " in spoken
    assert spoken.count(".") <= 3 and "More later" not in spoken  # two sentences at most
    assert speech.spoken("Long reply\n🔊 Your build passed.") == "Your build passed."
    assert "🔊" not in speech.body("Long reply\n🔊 Your build passed.")
    assert speech.spoken("CPU at 45%, ~3 GB") == "CPU at 45 percent, about 3 GB."
    assert "a code block" in speech.spoken("Here:\n```\nls -la\n```")
    assert speech.spoken("[fichier: https://gofile.io/d/abc]").startswith("a file from gofile.io")
    assert len(speech.body("word " * 200)) <= speech.BODY_MAX
    assert speech.spoken("Use file_a and file_b, *really*.") == "Use file_a and file_b, really."
    q = speech.question_spoken("clarify", "Which day?", None, ["Monday", "Tuesday", "Other"])
    assert q == "Hermes asks: Which day? Options: Monday, Tuesday."


def test_pet_needs() -> None:
    n = Needs(updated=0.0)
    n.advance(3600.0, working_seconds=0)
    assert round(n.hunger) == 4 and round(n.energy) == 97 and round(n.happiness) == 98
    n.advance(7200.0, working_seconds=3600)
    assert round(n.hunger) == 12 and round(n.energy) == 91
    assert n.act("feed", 7200.0) is None and round(n.hunger) == 0
    assert n.act("feed", 7200.0) == "not hungry"
    n.energy = 10
    assert n.act("play", 7200.0) == "too tired"
    assert n.act("sleep", 7200.0) is None and n.asleep and n.mood(False) == "asleep"
    n.advance(7200.0 + 8 * 3600, 0)
    assert not n.asleep and n.energy == 100  # woke up rested
    assert xp_for_level(1) == 100 and level_for(99) == 1 and level_for(100) == 2 and level_for(300) == 3
    n.xp = 95
    assert n.gain(10, 1.0) and n.burst == "jump"
    n2 = Needs(hunger=80)
    assert n2.mood(True) == "hungry"


def test_usage() -> None:
    ledger = usage.Ledger(Path(TMP) / "usage.db", [{"provider": "opencode-go", "model": "ds"},
                                                   {"provider": "openai-codex", "model": "gpt"}])
    now = 1_800_000_000.0
    u = {"input_tokens": 100, "cache_read_tokens": 900, "output_tokens": 50, "prompt_tokens": 1000}
    ledger.record("opencode-go", "ds", usage=u, cost=0.01, now=now)
    ledger.record("opencode-go", "ds", usage=u, cost=0.01, now=now - 2 * 86400)
    ledger.record("opencode-go", "ds", error=True, now=now)
    ledger.record("openai-codex", "gpt", usage=u, now=now - 3600)
    ledger.record("opencode-go", "flash", aux=True, usage=u, now=now)
    ledger.record("uzu", "local", usage=u, now=now)
    rows = {(m["provider"], m["model"]): m for m in ledger.summary(now)}
    main = rows[("opencode-go", "ds")]
    assert main["role"] == "main"
    assert main["windows"]["24h"] == {"calls": 1, "tokens_in": 1000, "tokens_out": 50, "tokens_cached": 900,
                                      "cost_usd": 0.01, "errors": 1}
    assert main["windows"]["7d"]["calls"] == 2 and main["windows"]["7d"]["cost_usd"] == 0.02
    assert rows[("openai-codex", "gpt")]["role"] == "fallback"
    assert rows[("openai-codex", "gpt")]["windows"]["24h"]["cost_usd"] is None
    assert rows[("opencode-go", "flash")]["role"] == "background"
    assert rows[("uzu", "local")]["role"] == "local"
    assert usage.tokens({"input_tokens": 5, "cache_read_tokens": 2, "output_tokens": 1}) == (7, 1, 2)


def test_machine() -> None:
    import plistlib

    raw = plistlib.dumps([{"ExternalConnected": True, "PowerTelemetryData": {"SystemPowerIn": 12500},
                           "CurrentCapacity": 100, "MaxCapacity": 100, "IsCharging": False, "Temperature": 3050}])
    info = machine.battery_info(raw)
    assert info["power_w"] == 12.5 and info["battery_pct"] == 100 and info["on_ac"] and info["battery_temp_c"] == 30.5
    raw = plistlib.dumps([{"ExternalConnected": False, "InstantAmperage": (1 << 64) - 1500, "Voltage": 12000,
                           "CurrentCapacity": 80, "MaxCapacity": 100}])
    assert machine.battery_info(raw)["power_w"] == 18.0
    m = machine.Machine(Path(TMP) / "machine.json", battery=lambda: {"power_w": 10.0})
    t = 1_800_000_000.0
    m.sample(t)
    m.sample(t + 60)
    m.sample(t + 3600)
    snap = m.snapshot()
    assert snap["ram_total"] > 0 and snap["disk_total"] > 0 and snap["power_w"] == 10.0
    assert len(snap["history"]["cpu"]) == 2 and snap["energy_kwh_24h"] > 0


def test_questions() -> None:
    from telegram import InlineKeyboardButton as B, InlineKeyboardMarkup as M

    changes = []
    qs = questions.Questions(lambda: changes.append(1))
    qs.add_summary("rm -rf ~/tmp/x", "Delete a temp folder")
    card = M([[B("Once", callback_data="ea:once:7"), B("Deny", callback_data="ea:deny:7")]])
    item = qs.from_card(chat=0, message_id=10, text_html="⚠️ <b>Dangerous</b>\n<pre>rm -rf ~/tmp/x</pre>", markup=card)
    assert item["id"] == "ea:7" and item["kind"] == "approval" and item["command"] == "rm -rf ~/tmp/x"
    assert item["summary"] == "Delete a temp folder" and item["spoken"].endswith("Allow?")
    assert base64.b64decode(item["options"][0]["data_b64"]).decode() == "ea:once:7"
    clar = M([[B("1", callback_data="cl:ab:0")], [B("2", callback_data="cl:ab:1")], [B("✏️ Other", callback_data="cl:ab:other")]])
    item = qs.from_card(chat=5, message_id=11, text_html="❓ Which?\n\n1. Monday\n2. Tuesday", markup=clar)
    assert item["kind"] == "clarify" and [o["label"] for o in item["options"]][:2] == ["Monday", "Tuesday"]
    assert qs.from_card(chat=0, message_id=12, text_html="pick", markup=M([[B("x", callback_data="mp:foo")]])) is None
    assert len(qs.public()) == 2
    assert not qs.resolve_callback("cl:ab:other")
    assert qs.resolve_callback("ea:deny:7") and [q["id"] for q in qs.public()] == ["cl:ab"]
    assert qs.resolve(kind="clarify", chat=5) and qs.public() == []


def test_status() -> None:
    s = Status(lambda: None, lambda: OWNER)
    assert tool_label("terminal", {"command": "nix build .#x\nmore"}) == "terminal: nix build .#x"
    s.pre_api_request(session_id="a")
    assert s.snapshot(False)["status"] == "thinking"
    s.pre_tool_call(tool_name="terminal", args={"command": "ls"}, session_id="a")
    snap = s.snapshot(False)
    assert snap["status"] == "working" and snap["task"] == "terminal: ls" and snap["progress"] == "1 tool calls"
    assert s.snapshot(True)["status"] == "waiting_user"
    s.end(session_id="a", failed=True)
    assert s.snapshot(False)["status"] == "error"
    s.pre_api_request(session_id="b")
    s.end(session_id="b")
    assert s.snapshot(False)["status"] == "idle" and len(s.take_finished()) == 2


def test_call_pieces() -> None:
    chunks, offset = call.split_ready("Hello there, Arthur. I am check", 0, False)
    assert chunks == ["Hello there, Arthur."] and offset == len("Hello there, Arthur.")
    chunks, offset = call.split_ready("Hello there, Arthur. I am checking.", offset, True)
    assert chunks == ["I am checking."]
    tokens = call.Tokens()
    token, _ = tokens.issue()
    assert tokens.take(token) and not tokens.take(token) and not tokens.take("nope")
    silence, loud = b"\x00\x00" * 960, struct.pack("<960h", *([8000, -8000] * 480))
    assert call.rms(silence) == 0 and call.rms(loud) > 7000


def test_gofile_token() -> None:
    a = bigfiles.Gofile.website_token("tok", now=0)
    assert a == bigfiles.Gofile.website_token("tok", now=14399) != bigfiles.Gofile.website_token("tok", now=14400)
    assert bigfiles.links("see\n[fichier: https://gofile.io/d/Ab12]\n[fichier: https://x.y/z.bin]") == [
        "https://gofile.io/d/Ab12", "https://x.y/z.bin"]


# ── the plugin on a fake Telegram ────────────────────────────────────────

class Bot:
    def __init__(self):
        self.next_id = 100
        self.messages: dict[int, dict] = {}
        self.calls: list[tuple[str, dict]] = []
        self.topics = 0

    def _id(self):
        self.next_id += 1
        return self.next_id

    async def create_forum_topic(self, chat_id, name):
        self.topics += 1
        self.calls.append(("create_forum_topic", {"chat_id": chat_id, "name": name}))
        return types.SimpleNamespace(message_thread_id=77)

    async def send_message(self, **kw):
        mid = self._id()
        self.messages[mid] = kw
        self.calls.append(("send_message", kw))
        return types.SimpleNamespace(message_id=mid)

    async def edit_message_text(self, **kw):
        if kw["message_id"] not in self.messages:
            raise RuntimeError("Bad Request: message to edit not found")
        if self.messages[kw["message_id"]]["text"] == kw["text"]:
            raise RuntimeError("Bad Request: message is not modified")
        self.messages[kw["message_id"]]["text"] = kw["text"]
        self.calls.append(("edit_message_text", kw))
        return True

    async def delete_message(self, **kw):
        self.messages.pop(kw["message_id"], None)
        self.calls.append(("delete_message", kw))
        return True

    async def send_document(self, **kw):
        kw["data"] = kw.pop("document").read()
        mid = self._id()
        self.messages[mid] = kw
        self.calls.append(("send_document", kw))
        return types.SimpleNamespace(message_id=mid)

    def in_topic(self, type_):
        out = []
        for mid, kw in sorted(self.messages.items()):
            if kw.get("message_thread_id") == 77 and "text" in kw:
                body = questions.html_to_text(kw["text"])
                obj = json.loads(body)
                if obj["type"] == type_:
                    out.append((mid, obj))
        return out


class Adapter:
    def __init__(self, bot):
        self._bot = bot

    @staticmethod
    def _notification_kwargs(metadata):
        return {"disable_notification": True} if (metadata or {}).get("silent") else {}

    async def send(self, chat_id, content, reply_to=None, metadata=None):
        msg = await self._bot.send_message(chat_id=chat_id, text=content)
        return types.SimpleNamespace(success=True, message_id=str(msg.message_id))

    async def edit_message(self, chat_id, message_id, content, *, finalize=False, metadata=None):
        return types.SimpleNamespace(success=True, message_id=message_id)

    async def send_draft(self, chat_id, draft_id, content, metadata=None):
        return types.SimpleNamespace(success=True)

    async def _send_control_message(self, chat_id, text, *, parse_mode=None, thread_id=None, metadata=None,
                                    reply_markup=None, reply_to_mode=None):
        return await self._bot.send_message(chat_id=chat_id, text=text, reply_markup=reply_markup)


class PTBApp:
    def __init__(self, bot):
        self.bot, self.handlers = bot, []

    def add_handler(self, handler, group=0):
        self.handlers.append((group, handler))


def make_pet(home: Path, slug: str) -> None:
    from PIL import Image

    d = home / "pets" / slug
    d.mkdir(parents=True, exist_ok=True)
    sheet = Image.new("RGBA", (1536, 1872), (0, 0, 0, 0))
    for x in range(40, 150):
        for y in range(40, 170):
            sheet.putpixel((x, y), (200, 80, 40, 255))
    sheet.save(d / "spritesheet.webp", format="WEBP", lossless=True)
    (d / "pet.json").write_text(json.dumps({"id": slug, "displayName": slug.capitalize(), "description": "test",
                                            "spritesheetPath": "spritesheet.webp", "createdBy": "generator"}))


def test_plugin() -> None:
    home = Path(os.environ["HERMES_HOME"])
    make_pet(home, "pip")
    (home / "app").mkdir(exist_ok=True)
    (home / "app" / "delivery.json").write_text(json.dumps({"v": 1, "devices": [{"id": "u1", "name": "iPhone"}]}))
    loop = asyncio.new_event_loop()
    threading.Thread(target=loop.run_forever, daemon=True).start()
    bot = Bot()
    adapter = Adapter(bot)
    plugin = app_mod.App(home, {"chain": [{"provider": "p", "model": "m"}], "delivery_cli": "/nonexistent/hermes-app"})
    plugin.loop = loop
    asyncio.run_coroutine_threadsafe(asyncio.sleep(0), loop).result()
    loop.call_soon_threadsafe(plugin.attach, PTBApp(bot), adapter)

    # The topic, its three slots, and the sprite.
    wait_for(lambda: bot.in_topic("state") and bot.in_topic("stats") and bot.in_topic("devices"), "the slots")
    assert bot.topics == 1 and plugin.saved["thread"] == 77
    assert all(kw.get("disable_notification") for name, kw in bot.calls if name == "send_message"
               and kw.get("message_thread_id") == 77)
    plugin.sync_pet()
    wait_for(lambda: any(n == "send_document" for n, _ in bot.calls), "the sprite")
    wait_for(lambda: (bot.in_topic("state")[-1][1].get("pet") or {}).get("id") == "pip", "the pet in the state")
    state = bot.in_topic("state")[-1][1]
    assert state["slots"]["stats"] == bot.in_topic("stats")[-1][0]
    assert state["pet"]["manifest"]["spritesheetPath"] == "spritesheet.webp" and state["pet"]["version"] == 1
    assert state["pet"]["sprite_message_id"] == state["slots"]["sprite"]
    assert bot.in_topic("devices")[-1][1]["delivery"]["devices"][0]["id"] == "u1"
    pet_dir = home / "app" / "pet"
    from PIL import Image

    assert Image.open(pet_dir / "icon.png").size == (1024, 1024) and Image.open(pet_dir / "icon.png").mode == "RGB"
    assert json.loads((pet_dir / "pet.json").read_text())["version"] == 1

    # A request in the App topic never becomes a turn, gets a reply, and is deleted.
    def event(text, thread="77", user=str(OWNER), mid="555"):
        src = types.SimpleNamespace(platform=types.SimpleNamespace(value="telegram"), chat_id=str(OWNER),
                                    thread_id=thread, user_id=user, message_id=mid)
        return types.SimpleNamespace(source=src, text=text, message_id=mid)

    assert plugin.dispatch(event("hi", thread=None)) is None
    assert plugin.dispatch(event('{"v":1,"type":"pet.play"}'))["action"] == "skip"
    wait_for(lambda: bot.in_topic("reply"), "a reply")
    reply = bot.in_topic("reply")[-1][1]
    assert reply["re"] == 555 and reply["ok"] and reply["data"]["happiness"] == 100
    assert ("delete_message", {"chat_id": OWNER, "message_id": 555}) in bot.calls
    plugin.dispatch(event('{"v":1,"type":"nope"}', mid="556"))
    wait_for(lambda: len(bot.in_topic("reply")) == 2, "an error reply")
    assert bot.in_topic("reply")[-1][1]["error"]["code"] == "unknown_type"
    plugin.dispatch(event('{"v":1,"type":"app.reinstall"}', mid="557"))
    wait_for(lambda: len(bot.in_topic("reply")) == 3, "reinstall's reply")
    assert bot.in_topic("reply")[-1][1]["error"]["code"] == "unavailable"
    plugin.dispatch(event('{"v":1,"type":"call.start"}', mid="558"))
    wait_for(lambda: len(bot.in_topic("reply")) == 4, "call.start's reply")
    assert bot.in_topic("reply")[-1][1]["error"]["code"] == "unavailable"

    # Status: a tool call shows in the state.
    plugin.status.pre_tool_call(tool_name="terminal", args={"command": "make"}, session_id="s1")
    wait_for(lambda: bot.in_topic("state")[-1][1]["agent"]["status"] == "working", "working")
    assert bot.in_topic("state")[-1][1]["pet"]["animation"] == "run"

    # Hermes' reply in the main chat: a notify with its spoken text, once.
    async def reply_send():
        await adapter.send(str(OWNER), "**Done.** The build passed → https://ci.example.com/1. Details follow.")
    asyncio.run_coroutine_threadsafe(reply_send(), loop).result()
    wait_for(lambda: bot.in_topic("notify"), "a notify")
    notify = bot.in_topic("notify")[-1][1]
    assert notify["chat"] == 0 and notify["kind"] == "message" and notify["interruption"] == "active"
    assert notify["spoken"] == "Done. The build passed to a link to ci.example.com."
    asyncio.run_coroutine_threadsafe(
        adapter.edit_message(str(OWNER), str(notify["message_id"]), "edited"), loop).result()
    asyncio.run_coroutine_threadsafe(adapter.send(str(OWNER), "A quiet notice", metadata={"silent": True}), loop).result()
    time.sleep(0.5)
    assert len(bot.in_topic("notify")) == 1

    # An approval card: a question in the state, a time-sensitive notify; a tap clears it.
    from telegram import InlineKeyboardButton as B, InlineKeyboardMarkup as M

    async def card():
        return await adapter._send_control_message(
            str(OWNER), "⚠️ Dangerous\n<pre>rm -rf /tmp/x</pre>", parse_mode="HTML", thread_id=None,
            metadata=None, reply_markup=M([[B("Once", callback_data="ea:once:3"), B("Deny", callback_data="ea:deny:3")]]))
    asyncio.run_coroutine_threadsafe(card(), loop).result()
    wait_for(lambda: bot.in_topic("state")[-1][1]["questions"], "the question")
    q = bot.in_topic("state")[-1][1]["questions"][0]
    assert q["kind"] == "approval" and q["command"] == "rm -rf /tmp/x"
    assert bot.in_topic("state")[-1][1]["agent"]["status"] == "waiting_user"
    wait_for(lambda: any(n[1]["kind"] == "approval" for n in bot.in_topic("notify")), "the approval notify")
    assert [n for n in bot.in_topic("notify") if n[1]["kind"] == "approval"][0][1]["interruption"] == "time-sensitive"
    tap = types.SimpleNamespace(callback_query=types.SimpleNamespace(data="ea:deny:3",
                                                                     from_user=types.SimpleNamespace(id=OWNER)))
    asyncio.run_coroutine_threadsafe(plugin.on_callback(tap), loop).result()
    wait_for(lambda: not bot.in_topic("state")[-1][1]["questions"], "the question answered")

    # Usage hooks feed the stats slot.
    plugin.post_api_request(provider="p", model="m", usage={"input_tokens": 10, "output_tokens": 2})
    plugin.dispatch(event('{"v":1,"type":"stats.refresh"}', mid="559"))
    wait_for(lambda: bot.in_topic("stats")[-1][1]["models"], "the usage in the stats")
    assert bot.in_topic("stats")[-1][1]["models"][0]["role"] == "main"

    # A deleted slot message is posted again (the newest wins).
    state_id = plugin.saved["slots"]["state"]["id"]
    bot.messages.pop(state_id)
    plugin.status.end(session_id="s1")
    wait_for(lambda: plugin.saved["slots"]["state"]["id"] != state_id, "a new state message")

    # A topic gone: a new one.
    plugin._topic_gone(RuntimeError("Bad Request: message thread not found"))
    wait_for(lambda: bot.topics == 2, "a new topic")
    plugin.stop.set()

    async def shutdown():
        for task in plugin.tasks:
            task.cancel()
        await asyncio.gather(*plugin.tasks, return_exceptions=True)
    asyncio.run_coroutine_threadsafe(shutdown(), loop).result(10)
    loop.call_soon_threadsafe(loop.stop)


def main() -> None:
    tests = [v for k, v in globals().items() if k.startswith("test_") and callable(v)]
    for test in tests:
        print("-", test.__name__)
        test()
    print("ok:", len(tests), "tests")


if __name__ == "__main__":
    main()
