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
from app_topic import bigfiles, machine, protocol, questions, speech, usage  # noqa: E402
from app_topic.pet import BEAT, PetState, animation, mood  # noqa: E402
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
    assert protocol.parse('{"v":1,"type":"stats.refresh"}') == {"v": 1, "type": "stats.refresh"}
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
    # No more spoken override: a "🔊" line is dropped, the spoken text derived.
    assert speech.spoken("Long reply.\n🔊 Your build passed.") == "Long reply."
    assert "🔊" not in speech.body("Long reply\n🔊 Your build passed.")
    assert speech.outgoing("Done.\n🔊 Done, said aloud.") == ("Done.", None)
    # A call's written detail leaves as its own message, never spoken.
    main, detail = speech.outgoing("It's at 3 pm.\n\n📎 Details\n- https://cal.example.com/e/1\n- Room 4")
    assert main == "It's at 3 pm." and detail == "📎 Details\n- https://cal.example.com/e/1\n- Room 4"
    assert speech.outgoing("📎 already a detail") == ("📎 already a detail", None)
    assert speech.spoken("📎 https://example.com") == "" and speech.body("📎 a link") == "a link"
    assert speech.spoken("CPU at 45%, ~3 GB") == "CPU at 45 percent, about 3 GB."
    assert "a code block" in speech.spoken("Here:\n```\nls -la\n```")
    assert speech.spoken("[fichier: https://gofile.io/d/abc]").startswith("a file from gofile.io")
    assert len(speech.body("word " * 200)) <= speech.BODY_MAX
    assert speech.spoken("Use file_a and file_b, *really*.") == "Use file_a and file_b, really."
    said = "Hermes veut supprimer le dossier build. Le mode auto demande parce que tu es en mode ask."
    assert speech.question_spoken("approval", "<terminal> (plugin approval rule)", said, []) == said
    assert speech.question_spoken("approval", "<terminal> (plugin approval rule)", None, []) \
        == "Hermes asks to use terminal. Allow?"
    q = speech.question_spoken("clarify", "Which day?", None, ["Monday", "Tuesday", "Other"])
    assert q == "Hermes asks: Which day? Options: Monday, Tuesday."


def test_pet_mood() -> None:
    # The pet only mirrors Hermes: what it does, then a short beat when a turn ends.
    assert mood("idle", "", 0.0, 100.0) == "idle" and animation("idle", "", 0.0, 100.0) == "idle"
    assert mood("thinking", "", 0.0, 0.0) == "working" and animation("thinking", "", 0.0, 0.0) == "review"
    assert mood("working", "", 0.0, 0.0) == "working" and animation("working", "", 0.0, 0.0) == "run"
    assert mood("waiting_user", "happy", 10.0, 1.0) == "waiting" and animation("waiting_user", "", 0.0, 1.0) == "waiting"
    assert mood("idle", "happy", 10.0, 1.0) == "happy" and animation("idle", "happy", 10.0, 1.0) == "jump"
    assert mood("error", "confused", 10.0, 1.0) == "confused" and animation("error", "confused", 10.0, 1.0) == "failed"
    # A beat is a reaction: once over, an error still on agent.status leaves the pet idle.
    assert mood("error", "confused", 10.0, 11.0) == "idle" and animation("error", "confused", 10.0, 11.0) == "idle"
    assert mood("working", "happy", 10.0, 1.0) == "working"
    # The old tamagotchi state on disk is read without its needs, and the pet keeps its version.
    d = Path(TMP) / "pet-v2"
    d.mkdir()
    (d / "pet-state.json").write_text(json.dumps({"slug": "pip", "version": 4, "needs": {"hunger": 90, "xp": 1}}))
    pet = PetState(d)
    assert pet.data == {"slug": "pip", "version": 4} and pet.adopt("pip") == 4 and pet.adopt("kiwi") == 5
    assert json.loads((d / "pet-state.json").read_text()) == {"slug": "kiwi", "version": 5}
    pet.react("happy", 0.0)
    assert pet.beat_until == BEAT


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
    qs.add_summary("rm -rf ~/tmp/x", "Hermes wants to delete a temp folder.", "terminal: rm -rf ~/tmp/x")
    card = M([[B("Once", callback_data="ea:once:7"), B("Deny", callback_data="ea:deny:7")]])
    item = qs.from_card(chat=0, message_id=10, text_html="⚠️ <b>Dangerous</b>\n<pre>rm -rf ~/tmp/x</pre>", markup=card)
    assert item["id"] == "ea:7" and item["kind"] == "approval" and item["command"] == "rm -rf ~/tmp/x"
    assert item["summary"] == "Hermes wants to delete a temp folder." == item["spoken"]
    assert item["detail"] == "terminal: rm -rf ~/tmp/x"
    assert base64.b64decode(item["options"][0]["data_b64"]).decode() == "ea:once:7"
    clar = M([[B("1", callback_data="cl:ab:0")], [B("2", callback_data="cl:ab:1")], [B("✏️ Other", callback_data="cl:ab:other")]])
    item = qs.from_card(chat=5, message_id=11, text_html="❓ Which?\n\n1. Monday\n2. Tuesday", markup=clar)
    assert item["kind"] == "clarify" and [o["label"] for o in item["options"]][:2] == ["Monday", "Tuesday"]
    # The question alone: the buttons are the options, the skip hint is Telegram's.
    assert item["text"] == "Which?", item["text"]
    item = qs.from_card(chat=5, message_id=15, markup=clar, text_html=(
        "❓ Quel jour pour le dentiste ?\nRépondez « skip » pour passer cette question.\n\n1. Lundi\n2. Mardi"))
    assert item["kind"] == "clarify" and item["text"].startswith("Quel jour pour le dentiste ?"), item["text"]
    assert item["text"] == "Quel jour pour le dentiste ?" and "Lundi" in item["spoken"], item
    # Hermes' translations not loaded: the hint arrives as its key.
    item = qs.from_card(chat=5, message_id=16, markup=clar, text_html="❓ Which day?\ngateway.clarify.skip_hint\n\n1. Lundi\n2. Mardi")
    assert item["text"] == "Which day?", item["text"]
    # A question that only mentions the word is kept.
    assert questions.is_skip_hint("Répondez « skip » pour passer cette question.")
    assert not questions.is_skip_hint("Should I skip the backup tonight?")
    item = qs.from_card(chat=5, message_id=16, markup=clar, text_html=(
        '❓ Which day?\nReply "skip" to skip this question.\n\n1. Monday\n2. Tuesday'))
    assert item["text"] == "Which day?" and item["spoken"] == "Hermes asks: Which day? Options: Monday, Tuesday.", item
    qs.resolve("cl:ab")
    prop = M([[B("1. Reply to Léa", callback_data="op:k1:0")], [B("2. Ignore", callback_data="op:k1:1")]])
    item = qs.from_card(chat=0, message_id=17, markup=prop, text_html="Léa invites you.\n\n1. Reply to Léa\n2. Ignore")
    assert item["kind"] == "proposal" and item["text"] == "Léa invites you.", item
    qs.resolve("op:k1")
    item = qs.from_card(chat=5, message_id=11, text_html="❓ Which?\n\n1. Monday\n2. Tuesday", markup=clar)
    assert qs.from_card(chat=0, message_id=12, text_html="pick", markup=M([[B("x", callback_data="mp:foo")]])) is None
    assert len(qs.public()) == 2
    # guard's summary of a command the card cut: the one reported just before.
    import app_topic as plugin_pkg

    sys.modules["guard"] = types.SimpleNamespace(
        card_summary=lambda d: d.split("\n\n")[0] if "auto-review" in d else None,
        card_detail=lambda d: d.split("\n\n")[1] if "auto-review" in d else None)
    fake_app = types.SimpleNamespace(questions=qs)
    plugin_pkg.STATE["app"] = fake_app
    plugin_pkg.pre_approval_request(command="curl -X POST " + "x" * 3000,
                                    description="Send your notes to a server\n\ncurl … (auto-review: risky)")
    long_card = M([[B("Once", callback_data="ea:once:8")]])
    item = qs.from_card(chat=0, message_id=13, text_html="<pre>curl -X POST xxx...</pre>", markup=long_card)
    assert item["summary"] == "Send your notes to a server" and item["detail"].startswith("curl"), item
    plugin_pkg.pre_approval_request(command="rm -rf /", description="recursive delete")
    item = qs.from_card(chat=0, message_id=14, text_html="<pre>rm -rf /</pre>", markup=M([[B("Once", callback_data="ea:once:9")]]))
    assert item["summary"] is None and item["detail"] is None
    qs.resolve("ea:8"), qs.resolve("ea:9")
    plugin_pkg.STATE["app"] = None
    del sys.modules["guard"]
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
    assert s.snapshot(False)["status"] == "idle" and s.take_finished() == [("a", "failed"), ("b", "done")]
    s.pre_api_request(session_id="c")
    s.end(session_id="c", failed=True, interrupted=True)
    assert s.take_finished() == [("c", "interrupted")]


def test_call_turn() -> None:
    import app_topic as plugin_pkg

    assert plugin_pkg.call_turn(user_message="\U0001f399 what time is it")["context"].startswith("[This message was spoken")
    assert plugin_pkg.call_turn(user_message="  \U0001f399 hi") is not None
    assert plugin_pkg.call_turn(user_message="what time is it") is None
    assert plugin_pkg.call_turn(user_message=[{"type": "text", "text": "x"}]) is None
    fake = types.SimpleNamespace(call_until=time.time() + 60)
    fake.call_active = lambda: time.time() < fake.call_until
    plugin_pkg.STATE["app"] = fake
    assert plugin_pkg.call_turn(user_message="and tomorrow?", platform="telegram") is not None
    assert plugin_pkg.call_turn(user_message="and tomorrow?", platform="webhook") is None
    plugin_pkg.STATE["app"] = None


def test_subchats() -> None:
    from unii.policy import Chat, Policies

    root = Path(tempfile.mkdtemp(dir=TMP))
    policies = Policies({"presets": {"aside": {"ttl": "session"}, "secret": {"encrypted": True, "ttl": "7d"}},
                         "default_preset": "aside"}, str(root))
    secret = Chat("telegram", "dm", str(OWNER), "455")
    policies.set_preset(secret, "secret")
    policies.set_name(secret, "Taxes")
    policies.touch(secret, "s1")
    policies.set_preset(Chat("telegram", "dm", str(OWNER), "456"), "aside")
    policies.set_preset(Chat("telegram", "group", "-100", ""), "aside")  # a group: not a topic of the DM

    class Runtime:
        def __init__(self):
            self.policies, self.keys = policies, {}

        def chat_volumes(self, chat):
            return policies.policy(chat), f"own-{chat.thread}", []

        def encrypted(self, name, policy=None):
            return bool(policy and policy.encrypted)

        def is_locked(self, name, policy=None):
            return self.encrypted(name, policy) and name not in self.keys

    runtime = Runtime()
    sys.__dict__["_hermes_unii_state"] = {"runtime": runtime}
    try:
        plugin = types.SimpleNamespace(saved={"thread": 77})
        subs = app_mod.App.subchats(plugin)
        assert [s["topic_id"] for s in subs] == [455, 456], subs
        taxes = subs[0]
        assert taxes["name"] == "Taxes" and taxes["preset"] == "secret" and taxes["encrypted"] and not taxes["unlocked"]
        assert taxes["ttl"] == "7d" and taxes["expires_at"] is not None
        assert subs[1]["name"] is None and not subs[1]["encrypted"] and subs[1]["expires_at"] is None
        runtime.keys["own-455"] = b"k"
        assert app_mod.App.subchats(plugin)[0]["unlocked"]
    finally:
        sys.__dict__.pop("_hermes_unii_state", None)


def test_pending() -> None:
    from app_topic.pending import TTL, Pending

    changes = []
    p = Pending(lambda: changes.append(1))
    p.add(0, 10, "ping the build", now=1000)
    p.add(0, 10, "ping the build", now=1001)
    p.add(5, 11, "in a sub-chat", now=1000)
    p.add(0, 12, "", now=1000)  # a photo
    assert [i["message_id"] for i in p.public(now=1001)] == [10, 11, 12]
    p.taken(0, ["something else"])
    assert len(p.public(now=1001)) == 3
    p.taken(0, ["[steer] ping   the build"])  # whitespace aside, steered in
    assert [i["message_id"] for i in p.public(now=1001)] == [11, 12]
    p.taken(0, ["the photo's own turn"], turn_start=True)
    assert [i["message_id"] for i in p.public(now=1001)] == [11]
    assert p.public(now=1000 + TTL) == []


def test_notify_title() -> None:
    subs = [{"topic_id": 455, "name": "Taxes", "encrypted": True},
            {"topic_id": 456, "name": "Lisbon trip", "encrypted": False},
            {"topic_id": 457, "name": None, "encrypted": False}]
    # A private sub-chat's name never reaches a notification.
    title, private = app_mod.notify_title(subs, 455)
    assert title == "Hermes" and private, title
    assert "Taxes" not in title
    assert app_mod.notify_title(subs, 456) == ("Hermes · Lisbon trip", False)
    assert app_mod.notify_title(subs, 457) == ("Hermes", False)
    assert app_mod.notify_title(subs, 0) == ("Hermes", False)
    assert app_mod.notify_title(subs, None) == ("Hermes", False)
    assert app_mod.notify_title([], 455) == ("Hermes", False)


def test_private_notification() -> None:
    subs = [{"topic_id": 455, "name": "Taxes", "encrypted": True},
            {"topic_id": 456, "name": "Lisbon trip", "encrypted": False}]
    assert app_mod.is_private(subs, 455) and not app_mod.is_private(subs, 456)
    assert not app_mod.is_private(subs, 0) and not app_mod.is_private(subs, None)
    assert app_mod.private_notification("message") == ("New message", "New message from Hermes.")
    assert app_mod.private_notification("approval") == ("Hermes needs you", "Hermes needs your answer.")
    # The Live Activity push: nothing of a private chat's content.
    agent = {"status": "working", "task": "Filing the 2025 tax return", "chat": 455}
    question = {"id": "q", "kind": "clarify", "chat": 455, "text": "Which bank for the refund?",
                "summary": "Bank?", "options": [{"id": "1", "label": "Boursorama"}]}
    a, q = app_mod.activity_redacted(subs, agent, question)
    assert a["task"] is None and a["status"] == "working"
    assert q["text"] == "" and q["summary"] is None and q["options"] == [] and q["id"] == "q"
    approval = {"id": "a", "kind": "approval", "chat": 455, "text": "rm -rf taxes/", "command": "rm -rf taxes/",
                "options": [{"id": "once", "label": "Allow Once"}]}
    _, q = app_mod.activity_redacted(subs, agent, approval)
    assert q["command"] is None and q["text"] == "" and q["options"] == approval["options"]
    # Elsewhere, untouched.
    public = {**agent, "chat": 456}
    assert app_mod.activity_redacted(subs, public, {**question, "chat": 456}) == (public, {**question, "chat": 456})


async def _private_notify_reaches_nothing() -> None:
    posted, pushed = [], []
    app = app_mod.App.__new__(app_mod.App)
    app.subchats = lambda: [{"topic_id": 455, "name": "Taxes", "encrypted": True}]
    async def post(obj): posted.append(obj)
    async def push(obj): pushed.append(obj)
    app.post = post
    app.extra_handlers = {"_push_notify": push}
    await app.notify(455, 7, "message", "Your refund from Boursorama is 1,240 €", "Your refund is 1,240 euros.")
    await app.notify(455, 8, "approval", "rm -rf taxes/", "Hermes wants to delete the taxes folder.")
    for obj in posted + pushed:
        assert "Taxes" not in obj["title"] and obj["private"]
    assert [(o["body"], o["spoken"]) for o in posted] == [("New message", "New message from Hermes."),
                                                         ("Hermes needs you", "Hermes needs your answer.")]
    assert all("Boursorama" not in repr(o) and "rm -rf" not in repr(o) for o in posted + pushed)


def test_private_notify_reaches_nothing() -> None:
    import asyncio
    asyncio.run(_private_notify_reaches_nothing())


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

    async def set_message_reaction(self, **kw):
        self.calls.append(("set_message_reaction", kw))
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
        self.edited, self.drafts = [], []

    @staticmethod
    def _notification_kwargs(metadata):
        return {"disable_notification": True} if (metadata or {}).get("silent") else {}

    async def send(self, chat_id, content, reply_to=None, metadata=None):
        msg = await self._bot.send_message(chat_id=chat_id, text=content)
        return types.SimpleNamespace(success=True, message_id=str(msg.message_id))

    async def edit_message(self, chat_id, message_id, content, *, finalize=False, metadata=None):
        self.edited.append(content)
        return types.SimpleNamespace(success=True, message_id=message_id)

    async def send_draft(self, chat_id, draft_id, content, metadata=None):
        self.drafts.append(content)
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
    plugin = app_mod.App(home, {"chain": [{"provider": "p", "model": "m"}, {"provider": "q", "model": "n"}],
                                "local_model": True, "delivery_cli": "/nonexistent/hermes-app",
                                "presets": [{"name": "aside", "default": True, "ttl": "session"},
                                            {"name": "secret", "default": False, "encrypted": True}]})
    plugin.loop = loop
    asyncio.run_coroutine_threadsafe(asyncio.sleep(0), loop).result()
    loop.call_soon_threadsafe(plugin.attach, PTBApp(bot), adapter)

    # The topic, its three slots, and the sprite.
    wait_for(lambda: bot.in_topic("state") and bot.in_topic("stats") and bot.in_topic("devices")
             and bot.in_topic("controls"), "the slots")
    controls = bot.in_topic("controls")[-1][1]
    assert protocol.fits(controls)
    assert [m["role"] for m in controls["model"]["chain"]] == ["main", "fallback", "local"]
    assert controls["model"]["default"] == {"provider": "p", "model": "m", "role": "main"}
    assert controls["permission_mode"] is None and "permissions" not in [c["id"] for c in controls["commands"]]
    assert next(c for c in controls["commands"] if c["id"] == "sub.new")["where"] == "main"
    assert [p["name"] for p in controls["presets"]] == ["aside", "secret"]
    # The permission mode, once its plugin reports it.
    sys.modules["guard"] = types.SimpleNamespace(permission_mode=lambda: "auto", PERMISSION_MODES=("auto", "ask"))
    plugin.changed()
    wait_for(lambda: (bot.in_topic("controls")[-1][1]["permission_mode"] or {}).get("value") == "auto", "the mode")
    assert "permissions" in [c["id"] for c in bot.in_topic("controls")[-1][1]["commands"]]
    mode = bot.in_topic("controls")[-1][1]["permission_mode"]
    assert mode["set"] == "/mode {value}" and [o["id"] for o in mode["options"]] == ["auto", "ask"]
    assert mode["options"][1]["label"] == "Ask"
    del sys.modules["guard"]
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
    assert plugin.dispatch(event('{"v":3,"type":"hello","app_version":"1.0"}'))["action"] == "skip"
    wait_for(lambda: bot.in_topic("reply"), "a reply")
    reply = bot.in_topic("reply")[-1][1]
    assert reply["re"] == 555 and reply["ok"] and reply["data"]["protocol"] == 4 and reply["v"] == 4
    # Hello names the slot messages, so an app that can't page back to them reads them by id.
    slots = reply["data"]["slots"]
    assert set(slots) >= {"state", "stats", "controls", "devices"} and all(isinstance(i, int) for i in slots.values())
    assert ("delete_message", {"chat_id": OWNER, "message_id": 555}) in bot.calls
    plugin.dispatch(event('{"v":2,"type":"call.state","active":true}', mid="560"))
    wait_for(lambda: any(r[1]["re"] == 560 for r in bot.in_topic("reply")), "call.state's reply")
    assert plugin.call_active()
    plugin.dispatch(event('{"v":2,"type":"call.state","active":false}', mid="561"))
    wait_for(lambda: any(r[1]["re"] == 561 for r in bot.in_topic("reply")), "call.state off")
    assert not plugin.call_active()
    plugin.dispatch(event('{"v":1,"type":"nope"}', mid="556"))
    wait_for(lambda: any(r[1]["re"] == 556 for r in bot.in_topic("reply")), "an error reply")
    assert bot.in_topic("reply")[-1][1]["error"]["code"] == "unknown_type"
    plugin.dispatch(event('{"v":1,"type":"app.reinstall"}', mid="557"))
    wait_for(lambda: any(r[1]["re"] == 557 for r in bot.in_topic("reply")), "reinstall's reply")
    assert bot.in_topic("reply")[-1][1]["error"]["code"] == "unavailable"
    plugin.dispatch(event('{"v":1,"type":"call.start"}', mid="558"))
    wait_for(lambda: any(r[1]["re"] == 558 for r in bot.in_topic("reply")), "call.start's reply")
    assert bot.in_topic("reply")[-1][1]["error"]["code"] == "unknown_type"  # protocol v2: no call.start
    for n, kind in enumerate(("pet.feed", "pet.play", "pet.sleep", "pet.wake")):  # protocol v3: no tamagotchi
        plugin.dispatch(event(json.dumps({"v": 2, "type": kind}), mid=str(570 + n)))
        wait_for(lambda: any(r[1]["re"] == 570 + n for r in bot.in_topic("reply")), f"{kind}'s reply")
        assert bot.in_topic("reply")[-1][1]["error"]["code"] == "unknown_type"

    # Status: a tool call shows in the state.
    plugin.status.pre_tool_call(tool_name="terminal", args={"command": "make"}, session_id="s1")
    wait_for(lambda: bot.in_topic("state")[-1][1]["agent"]["status"] == "working", "working")
    pet = bot.in_topic("state")[-1][1]["pet"]
    assert pet["animation"] == "run" and pet["mood"] == "working" and pet["mood_until"] is None
    assert not {"hunger", "energy", "happiness", "xp", "level", "xp_next", "asleep"} & set(pet)

    # A message while that turn runs: pending in the state, a 👀 on it, until the turn takes it in.
    assert plugin.dispatch(event("also check the logs", thread=None, mid="901")) is None
    wait_for(lambda: bot.in_topic("state")[-1][1]["pending"], "the pending message")
    pending = bot.in_topic("state")[-1][1]["pending"]
    assert [(p["chat"], p["message_id"]) for p in pending] == [(0, 901)] and pending[0]["since"].endswith("Z")
    wait_for(lambda: any(n == "set_message_reaction" and kw["message_id"] == 901 for n, kw in bot.calls), "the 👀")
    plugin.dispatch(event("/status", thread=None, mid="902"))  # a command is never pending
    plugin.taken(session_id="s1", conversation_history=[
        {"role": "user", "content": "make it"},
        {"role": "user", "display_kind": "steer", "content": "<steer>Gateway message origin…\n\nalso check the logs</steer>"}])
    wait_for(lambda: bot.in_topic("state")[-1][1]["pending"] == [], "the message taken in")

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

    # A call reply: the spoken part goes as the message, the written detail after it, alone; no "🔊" line.
    def main_chat(since):
        return [kw["text"] for name, kw in bot.calls[since:]
                if name == "send_message" and kw.get("message_thread_id") is None and str(kw.get("chat_id")) == str(OWNER)]

    before = len(bot.calls)
    asyncio.run_coroutine_threadsafe(adapter.send(
        str(OWNER), "Your dentist is at 3 pm.\n🔊 Dentist at three.\n📎 Address: 4 rue X\nhttps://maps.example.com/1"),
        loop).result()
    texts = main_chat(before)
    assert texts == ["Your dentist is at 3 pm.", "📎 Address: 4 rue X\nhttps://maps.example.com/1"], texts
    wait_for(lambda: len(bot.in_topic("notify")) >= 3, "the two notifies")
    spoken = [n[1]["spoken"] for n in bot.in_topic("notify")[-2:]]
    assert spoken == ["Your dentist is at 3 pm.", ""], spoken
    # A streamed reply: edits stop at the detail line; the final edit sends it apart, once.
    before = len(bot.calls)
    full = "Two meetings tomorrow.\n📎 9:00 standup\n14:00 review"
    for finalize in (False, True, True):
        asyncio.run_coroutine_threadsafe(adapter.edit_message(str(OWNER), "777", full, finalize=finalize), loop).result()
    assert main_chat(before) == ["📎 9:00 standup\n14:00 review"], main_chat(before)
    assert adapter.edited[-1] == "Two meetings tomorrow."
    asyncio.run_coroutine_threadsafe(adapter.send_draft(str(OWNER), 1, full), loop).result()
    assert adapter.drafts[-1] == "Two meetings tomorrow."

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
    # The keyboard's own message, by its Bot API id, in the chat it landed in.
    assert q["chat"] == 0 and bot.messages[q["message_id"]]["reply_markup"] is not None
    assert bot.in_topic("state")[-1][1]["agent"]["status"] == "waiting_user"
    wait_for(lambda: any(n[1]["kind"] == "approval" for n in bot.in_topic("notify")), "the approval notify")
    assert [n for n in bot.in_topic("notify") if n[1]["kind"] == "approval"][0][1]["interruption"] == "time-sensitive"
    tap = types.SimpleNamespace(callback_query=types.SimpleNamespace(data="ea:deny:3",
                                                                     from_user=types.SimpleNamespace(id=OWNER)))
    asyncio.run_coroutine_threadsafe(plugin.on_callback(tap), loop).result()
    wait_for(lambda: not bot.in_topic("state")[-1][1]["questions"], "the question answered")

    # Usage hooks feed the stats slot.
    plugin.post_api_request(provider="q", model="n", usage={"input_tokens": 10, "output_tokens": 2}, session_id="s9")
    plugin.changed()
    wait_for(lambda: bot.in_topic("controls")[-1][1]["model"]["last"].get("0", {}).get("model") == "n",
             "the last model of the main chat")
    plugin.dispatch(event('{"v":1,"type":"stats.refresh"}', mid="559"))
    wait_for(lambda: bot.in_topic("stats")[-1][1]["models"], "the usage in the stats")
    assert bot.in_topic("stats")[-1][1]["models"][0]["role"] == "fallback"

    # A deleted slot message is posted again (the newest wins).
    state_id = plugin.saved["slots"]["state"]["id"]
    bot.messages.pop(state_id)
    plugin.status.end(session_id="s1")
    wait_for(lambda: plugin.saved["slots"]["state"]["id"] != state_id, "a new state message")
    # The turn finished: a happy beat, with when it ends.
    wait_for(lambda: bot.in_topic("state")[-1][1]["pet"]["mood"] == "happy", "the happy beat")
    pet = bot.in_topic("state")[-1][1]["pet"]
    assert pet["animation"] == "jump" and pet["mood_until"]

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


def test_pet_provider_refusal() -> None:
    """A spent key stops a hatch at the first refusal, and says what to do."""
    from agent.pet.generate import imagegen

    error = ("OpenRouter rejected the API key (403): Key limit exceeded (monthly limit). Manage it using "
             "https://openrouter.ai/settings/keys $2.35 of $2.00 used; resets 2026-12-01T00:00:00.000Z.")
    assert app_mod.refusal({"success": False, "error": error, "error_type": "auth_error"})
    assert app_mod.refusal({"success": False, "error": "HTTP 402 insufficient credits", "error_type": "api_error"})
    assert not app_mod.refusal({"success": False, "error": "rate limit (429)", "error_type": "api_error"})
    assert not app_mod.refusal({"success": True, "image": "x.png"})
    plain = app_mod.plain_refusal("openrouter", error)
    assert plain.startswith("OpenRouter refused: the API key's spending limit is used up ($2.35 of $2.00, it "
                            "resets on 2026-12-01)."), plain
    assert "https://openrouter.ai/settings/keys" in plain and "bootstrap" in plain

    def refusing(after: int):
        def generate(fake, prompt, **kwargs):
            if len(fake.calls) > after:
                return {"success": False, "error": error, "error_type": "auth_error"}
            return None
        return generate

    real = imagegen.resolve_provider
    try:
        # Refused at the sheet: one call. Refused at a redrawn row: no third.
        for after, sheet in ((0, synthetic_sheet()), (1, synthetic_sheet(bad=("waving", "failed")))):
            fake = FakeImages(sheet, hook=refusing(after))
            imagegen.resolve_provider = lambda **_: imagegen.SpriteProvider("openrouter", fake, True)
            try:
                app_mod.generate_pet("a small red fox")
            except app_mod.ProviderRefused as refused:
                assert str(refused) == plain, str(refused)
                assert refused.report["budget"]["calls"][-1]["how"] == "not billed", refused.report
            else:
                raise AssertionError("no refusal")
            assert len(fake.calls) == after + 1, fake.calls
    finally:
        imagegen.resolve_provider = real


# ── one-sheet hatching (hatch.py) against a fake image provider ─────────

def _pose(draw, cx, cy, s, facing=1):
    draw.ellipse([cx - s, cy - s, cx + s, cy + s * 1.2], fill=(40, 120, 200), outline=(10, 10, 10), width=3)
    hx = cx + facing * s * 0.4
    draw.ellipse([hx - s * 0.45, cy - s * 1.6, hx + s * 0.45, cy - s * 0.7], fill=(230, 180, 60),
                 outline=(10, 10, 10), width=3)
    xs = sorted([cx + facing * s * 0.5, cx + facing * s * 1.0])
    draw.rectangle([xs[0], cy - s * 1.25, xs[1], cy - s * 1.05], fill=(240, 120, 20), outline=(10, 10, 10))


def synthetic_sheet(bad=(), left_faces_right=False, size=(1152, 1536)):
    """What the model is asked for: 9 rows of separated poses on magenta; a
    "bad" row is one smear the extraction cannot split."""
    from PIL import Image, ImageDraw

    from agent.pet.generate import atlas

    image = Image.new("RGB", size, (255, 0, 255))
    draw = ImageDraw.Draw(image)
    w, h = size
    band = h / 9
    for i, (state, _row, count) in enumerate(atlas.ROW_SPECS):
        cy = (i + 0.6) * band
        if state in bad:
            draw.rectangle([20, cy - 40, w - 20, cy + 40], fill=(40, 120, 200))
            continue
        facing = -1 if state == "running-left" and not left_faces_right else 1
        for col in range(count):
            _pose(draw, (col + 0.5) * w / count, cy + (col % 2) * 4, min(w / count, band) * 0.22, facing)
    return image


class FakeImages:
    """An image provider: the sheet for a portrait call, a clean strip for a
    row (its frame count read from Hermes' row prompt); reports a cost."""

    name = "openrouter"

    def __init__(self, sheet, sheet_cost=0.30, row_cost=0.06, hook=None, bad_rows=()) -> None:
        self.sheet, self.sheet_cost, self.row_cost, self.hook, self.bad_rows = sheet, sheet_cost, row_cost, hook, bad_rows
        self.calls: list[dict] = []
        self.lock = threading.Lock()

    def generate(self, prompt, **kwargs):
        from PIL import Image, ImageDraw

        with self.lock:
            self.calls.append(kwargs)
        if self.hook and (answer := self.hook(self, prompt, **kwargs)):
            return answer
        path = Path(tempfile.mkstemp(suffix=".png", dir=TMP)[1])
        if kwargs.get("aspect_ratio") == "portrait":
            self.sheet.save(path)
            return {"success": True, "image": str(path), "cost_usd": self.sheet_cost}
        count = int(prompt.split("strip of ")[1].split()[0])
        strip = Image.new("RGB", (1536, 1024), (255, 0, 255))
        draw = ImageDraw.Draw(strip)
        if not any(f"showing {s}" in prompt for s in self.bad_rows):  # a bad strip: nothing drawn
            for col in range(count):
                _pose(draw, (col + 0.5) * 1536 / count, 560, 1536 / count * 0.22)
        strip.save(path)
        return {"success": True, "image": str(path), "cost_usd": self.row_cost}


def _hatch(fake, **kwargs):
    from agent.pet.generate import imagegen

    from app_topic import hatch

    work = Path(tempfile.mkdtemp(dir=TMP))
    return hatch.hatch("a blue bird", sprite=imagegen.SpriteProvider("openrouter", fake, True), work=work,
                       **kwargs), work


def test_pet_one_sheet() -> None:
    """A good sheet: one call, a valid atlas, what it cost."""
    from agent.pet.generate import atlas

    from app_topic import hatch

    guide = hatch.layout_guide()
    assert guide.size == hatch.GUIDE_SIZE and guide.getpixel((0, 0)) == hatch.CHROMA
    fake = FakeImages(synthetic_sheet())
    (result, report), work = _hatch(fake)
    assert len(fake.calls) == 1, fake.calls
    call = fake.calls[0]
    assert call["aspect_ratio"] == "portrait" and call["aspect_ratio_exact"] == "3:4" and call["quality"] == "high"
    assert call["reference_images"] == [str(work / "guide.png")]
    assert result.size == (atlas.ATLAS_WIDTH, atlas.ATLAS_HEIGHT)
    assert atlas.validate_atlas(result)["ok"] and len(report["filled_states"]) == 9
    assert report["path"] == "one-sheet" and not report["repaired_rows"] and not report["mirrored_left"]
    assert report["budget"]["spent"] == 0.30 and report["budget"]["calls"][0]["how"] == "reported"
    for name in ("sheet.png", "spritesheet.png", "contact-sheet.png", "report.json"):
        assert (work / name).is_file(), name
    # The sheet's running-left faces right: mirrored from running-right, free.
    fake = FakeImages(synthetic_sheet(left_faces_right=True))
    (_, report), _ = _hatch(fake)
    assert len(fake.calls) == 1 and report["mirrored_left"] and report["row_errors"]["running-left"] == "faces right"


def test_pet_row_fallback() -> None:
    """A bad row is redrawn alone at quality medium on the idle frame; at
    most three rows; a redrawn row that fails again stops the hatch."""
    from app_topic import hatch

    fake = FakeImages(synthetic_sheet(bad=("waving",)))
    (_, report), work = _hatch(fake)
    assert len(fake.calls) == 2 and report["repaired_rows"] == ["waving"] and report["path"] == "one-sheet + rows"
    row = fake.calls[1]
    assert row["quality"] == "medium" and row["aspect_ratio"] == "landscape"
    assert row["reference_images"] == [str(work / "idle-reference.png")]
    assert report["budget"]["spent"] == 0.36, report["budget"]

    # A bad running-right brings running-left along: one redraw, then the mirror.
    fake = FakeImages(synthetic_sheet(bad=("running-right", "running-left")))
    (_, report), _ = _hatch(fake)
    assert report["repaired_rows"] == ["running-right"] and report["mirrored_left"], report

    fake = FakeImages(synthetic_sheet(bad=("waving", "jumping", "failed", "review")))
    try:
        _hatch(fake, max_cost=5)
    except hatch.HatchFailed as failed:
        assert "after 3 redrawn" in str(failed) and len(fake.calls) == 4, (failed, fake.calls)
        assert failed.report["repaired_rows"] == ["waving", "jumping", "failed"]
    else:
        raise AssertionError("more than three rows redrawn")

    fake = FakeImages(synthetic_sheet(bad=("waving",)), bad_rows=("a friendly greeting",))
    try:
        _hatch(fake)
    except hatch.HatchFailed as failed:
        assert "still unusable after it was redrawn" in str(failed) and len(fake.calls) == 2, failed
    else:
        raise AssertionError("a row redrawn twice")

    fake = FakeImages(synthetic_sheet(bad=("idle",)))
    try:
        _hatch(fake)
    except hatch.HatchFailed as failed:
        assert "unusable" in str(failed) and len(fake.calls) == 1, failed
    else:
        raise AssertionError("an unusable sheet hatched")


def test_pet_budget() -> None:
    """No call starts that could cross the budget; reported costs calibrate
    the estimates; generate_pet registers the pet and says what it spent."""
    from app_topic import hatch

    assert hatch.estimate("portrait", "high", 1) > hatch.estimate("landscape", "medium", 1) * 3
    fake = FakeImages(synthetic_sheet())
    try:
        _hatch(fake, max_cost=0.20)
    except hatch.HatchFailed as failed:
        assert "over budget" in str(failed) and not fake.calls, failed
    else:
        raise AssertionError("the sheet ignored the budget")

    # $0.42 reported for the sheet; a medium row then costs ~$0.15 by the calibrated estimate.
    fake = FakeImages(synthetic_sheet(bad=("waving",)), sheet_cost=0.42)
    try:
        _hatch(fake, max_cost=0.50)
    except hatch.HatchFailed as failed:
        assert "within the budget" in str(failed) and len(fake.calls) == 1, failed
        assert failed.report["budget"]["spent"] == 0.42
    else:
        raise AssertionError("a row ignored the budget")

    # No reported cost: the estimate is charged.
    fake = FakeImages(synthetic_sheet(), sheet_cost=None)
    (_, report), _ = _hatch(fake)
    assert report["budget"]["estimated"] == round(hatch.estimate("portrait", "high", 1), 4), report["budget"]

    from agent.pet import store
    from agent.pet.generate import imagegen

    real = imagegen.resolve_provider
    fake = FakeImages(synthetic_sheet(bad=("review",)))
    imagegen.resolve_provider = lambda **_: imagegen.SpriteProvider("openrouter", fake, True)
    try:
        result = app_mod.generate_pet("a blue bird", "Blue", max_cost=0.60)
    finally:
        imagegen.resolve_provider = real
    assert store.load_pet(result["slug"]).display_name == "Blue"
    assert app_mod.spent(result["report"]) == "$0.36 of the $0.60 budget", result["report"]["budget"]


def test_pet_redraw_rows() -> None:
    """One row of an existing pet redrawn alone, our calm "running" wording,
    the other rows kept pixel for pixel."""
    from agent.pet.generate import atlas, imagegen

    from app_topic import hatch

    fake = FakeImages(synthetic_sheet())
    (sheet, _), _ = _hatch(fake)
    fake = FakeImages(synthetic_sheet())
    prompts = []
    fake.hook = lambda _f, prompt, **_k: prompts.append(prompt) and None
    work = Path(tempfile.mkdtemp(dir=TMP))
    result, report = hatch.redraw(sheet, ["running"], "a blue bird",
                                  sprite=imagegen.SpriteProvider("openrouter", fake, True), work=work)
    assert len(fake.calls) == 1 and fake.calls[0]["quality"] == hatch.ROW_QUALITY
    assert "tiny hammer" in prompts[0] and "never angry" in prompts[0] and "concentrating" not in prompts[0], prompts[0]
    assert atlas.validate_atlas(result)["ok"] and report["repaired_rows"] == ["running"]
    before, after = hatch.atlas_frames(sheet), hatch.atlas_frames(result)
    for state, _row, count in atlas.ROW_SPECS:
        same = all(list(before[state][i].getdata()) == list(after[state][i].getdata()) for i in range(count))
        assert same == (state != "running"), state
    try:
        hatch.redraw(sheet, ["dancing"], "x", sprite=imagegen.SpriteProvider("openrouter", fake, True), work=work)
    except hatch.HatchFailed as failed:
        assert "dancing" in str(failed)
    else:
        raise AssertionError("an unknown row was redrawn")


def main() -> None:
    tests = [v for k, v in globals().items() if k.startswith("test_") and callable(v)]
    for test in tests:
        print("-", test.__name__)
        test()
    print("ok:", len(tests), "tests")


if __name__ == "__main__":
    main()
