"""Tests for unii's Hermes side: policies, the engine, hooks and /sub.

Run with Hermes' own interpreter (the flake check `unii`), from modules/hermes/plugins:

    python3 -I tests/test_unii.py
"""

import json
import os
import shutil
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from unii import policy as P  # noqa: E402
from unii.engine import UniiEngine, turn_start  # noqa: E402
from unii.hooks import Hooks  # noqa: E402
from unii.commands import SubCommand  # noqa: E402
from unii.runtime import Runtime  # noqa: E402

CONFIG = {
    "presets": {
        "aside": {"memoryRead": True, "ttl": "session"},
        "project": {"memoryRead": True, "volume": "projects"},
        "secret": {"volume": "vault", "encrypted": True, "model": "uzu:local", "tools": ["file"]},
        "temp": {"ttl": "1h", "model": "uzu:local", "tools": []},
    },
    "default_preset": "aside",
    "volumes": {"projects": {}, "vault": {"encrypted": True}},
    "view_bytes": 2000,
    "line_bytes": 120,
    "uzu_model": "alibaba:qwen3.5:4b:mirai:mirai-m:4",
}


def fake_complete(messages):
    """A compaction model that always answers a short line naming its input."""
    task = messages[-1]["content"]
    return "summary of " + task.split("<input>")[-1].strip()[:40].replace("\n", " ")


class Temp(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)


class PolicyTest(Temp):
    def test_chats_from_session_keys(self):
        dm = P.Chat.from_session_key("agent:main:whatsapp:dm:33612345678", "whatsapp")
        group = P.Chat.from_session_key("agent:main:whatsapp:group:1203@g.us", "whatsapp")
        self.assertTrue(dm.is_main)
        self.assertFalse(group.is_main)
        self.assertEqual(group.key, "whatsapp:group:1203@g.us")
        self.assertTrue(P.Chat.from_session_key(None, "cli").is_main)
        self.assertIsNone(P.Chat.from_session_key(None, "subagent"))

    def test_telegram_topics(self):
        root = P.Chat.from_session_key("agent:main:telegram:dm:123456789", "telegram")
        general = P.Chat.from_session_key("agent:main:telegram:dm:123456789:1", "telegram")
        topic = P.Chat.from_session_key("agent:main:telegram:dm:123456789:42", "telegram")
        group_topic = P.Chat.from_session_key("agent:main:telegram:group:-1001234567890:7", "telegram")
        self.assertTrue(root.is_main)
        self.assertTrue(general.is_main)
        self.assertEqual(root, general)
        self.assertFalse(topic.is_main)
        self.assertEqual(topic.key, "telegram:dm:123456789:42")
        self.assertEqual(P.Chat.from_key(topic.key), topic)
        self.assertEqual(group_topic.thread, "7")
        self.assertNotEqual(group_topic, P.Chat.from_session_key("agent:main:telegram:group:-1001234567890", "telegram"))

    def test_presets_overrides_and_ttl(self):
        policies = P.Policies(CONFIG, self.root)
        chat = P.Chat("whatsapp", "group", "g1")
        self.assertEqual(policies.policy(chat).ttl, "session")
        policies.set_preset(chat, "project")
        policies.set(chat, "tools", P.parse_setting("tools", "web,file"))
        reloaded = P.Policies(CONFIG, self.root).policy(chat)
        self.assertEqual(reloaded.volume, "projects")
        self.assertEqual(reloaded.tools, ("web", "file"))
        self.assertEqual(P.ttl_seconds("6h"), 21600)
        with self.assertRaises(ValueError):
            P.ttl_seconds("soon")
        # A named encrypted volume makes the chat encrypted.
        policies.set(chat, "volume", "vault")
        self.assertTrue(policies.policy(chat).encrypted)

    def test_expiry(self):
        policies = P.Policies(CONFIG, self.root)
        chat = P.Chat("whatsapp", "group", "g2")
        policies.set_preset(chat, "temp")
        policies.touch(chat, "s1")
        self.assertEqual(policies.expired(time.time() + 7200), [chat])
        self.assertEqual(policies.expired(time.time()), [])


class FakeStore:
    def __init__(self, keys):
        self.entries = [type("E", (), {"session_key": k}) for k in keys]
        self.overrides = {}
        self.resets = []

    def list_sessions(self):
        return self.entries

    def set_model_override(self, key, override):
        self.overrides[key] = override

    def get_model_override(self, key):
        return self.overrides.get(key)

    def reset_session(self, key):
        self.resets.append(key)


MAIN_KEY = "agent:main:whatsapp:dm:336"
# The agent sets group_sessions_per_user to false: no participant in group keys.
GROUP_KEY = "agent:main:whatsapp:group:g3@g.us"


def turn(user, reply, tool=None):
    out = [{"role": "user", "content": user, "message_uid": f"u-{user}"}]
    if tool:
        out.append({"role": "assistant", "content": "", "tool_calls": [
            {"id": "c1", "function": {"name": tool, "arguments": "{}"}}], "message_uid": f"a-{user}"})
        out.append({"role": "tool", "content": "tool said ok", "tool_call_id": "c1", "message_uid": f"t-{user}"})
    out.append({"role": "assistant", "content": reply, "message_uid": f"r-{user}"})
    return out


class EngineTest(Temp):
    def runtime(self):
        return Runtime(self.root, CONFIG, fake_complete)

    def engine(self, runtime, key, platform="whatsapp", sid="s"):
        engine = UniiEngine(runtime).clone_for_agent()
        engine.on_session_start(sid, platform=platform, conversation_id=key)
        return engine

    def test_turn_start(self):
        history = [{"role": "system", "content": "sys"}] + turn("a", "A") + turn("b", "B", tool="web_search")
        self.assertEqual(turn_start(history, finished=True), 3)
        self.assertEqual(turn_start(history[:-1], finished=False), 3)

    def test_main_chat_logs_and_selects_the_view(self):
        rt = self.runtime()
        main = self.engine(rt, MAIN_KEY)
        history = [{"role": "system", "content": "SYS"}] + turn("remember 7", "ok", tool="web_search")
        main.on_turn_complete(history)
        volume = rt.volume("main")
        self.assertEqual([m["kind"] for m in volume.messages], ["user", "tool", "echo", "hermes"])
        main.on_turn_complete(history)  # a second call logs nothing twice
        self.assertEqual(volume.count, 4)

        request = history + [{"role": "user", "content": "what number?"}]
        selected = main.select_context(request)
        self.assertEqual(selected[0], {"role": "system", "content": "SYS"})
        self.assertEqual(len(selected), 2)
        self.assertIn("<chat>\n0+1|user: remember 7", selected[1]["content"])
        self.assertTrue(selected[1]["content"].endswith("what number?"))
        self.assertIn("remember 7", json.loads(main.handle_tool_call("zoom", {"id": 0, "n": 1}))["result"])

    def test_sub_chat_reads_but_does_not_write_main(self):
        rt = self.runtime()
        main = self.engine(rt, MAIN_KEY, sid="m")
        main.on_turn_complete([{"role": "system", "content": "S"}] + turn("main fact", "noted"))
        sub = self.engine(rt, GROUP_KEY, sid="g")  # preset aside: memoryRead, no write
        sub.on_turn_complete([{"role": "system", "content": "S"}] + turn("side question", "side answer"))
        self.assertEqual(rt.volume("main").count, 2)
        own = P.own_volume(P.Chat("whatsapp", "group", "g3@g.us"))
        self.assertEqual(rt.volume(own).count, 2)
        selected = sub.select_context([{"role": "system", "content": "S"}, {"role": "user", "content": "q"}])
        self.assertIn("<main>\n0+1|user: main fact", selected[1]["content"])
        self.assertIn("<chat>\n0+1|user: side question", selected[1]["content"])

    def test_isolated_sub_chat_cannot_zoom_main(self):
        rt = self.runtime()
        chat = P.Chat("whatsapp", "group", "g3@g.us")
        rt.policies.set(chat, "memoryRead", False)
        sub = self.engine(rt, GROUP_KEY)
        answer = json.loads(sub.handle_tool_call("zoom", {"id": 0, "n": 1, "volume": "main"}))
        self.assertIn("not readable", answer["error"])

    def test_session_ttl_wipes_private_volume(self):
        rt = self.runtime()
        rt.session_store = FakeStore([GROUP_KEY])
        sub = self.engine(rt, GROUP_KEY)
        sub.on_turn_complete([{"role": "system", "content": "S"}] + turn("temp", "t"))
        own = P.own_volume(P.Chat("whatsapp", "group", "g3@g.us"))
        self.assertTrue(os.path.isdir(os.path.join(rt.volumes_dir, own)))
        # A gateway shutdown ends the session but wipes nothing.
        sub.on_session_end("s", [])
        self.assertTrue(os.path.isdir(os.path.join(rt.volumes_dir, own)))
        Hooks(rt).on_session_reset(session_id="s2", old_session_id="s", new_session_id="s2")
        self.assertFalse(os.path.isdir(os.path.join(rt.volumes_dir, own)))
        self.assertEqual(rt.session_store.resets, [])

    def test_subagent_is_passive(self):
        rt = self.runtime()
        child = self.engine(rt, None, platform="subagent")
        child.on_turn_complete([{"role": "system", "content": "S"}] + turn("task", "done"))
        self.assertEqual(rt.volume("main").count, 0)


class HooksTest(Temp):
    def test_tools_and_models_and_unlock(self):
        rt = Runtime(self.root, CONFIG, fake_complete)
        rt.session_store = FakeStore([GROUP_KEY])
        hooks = Hooks(rt)
        chat = P.Chat("whatsapp", "group", "g3@g.us")
        UniiEngine(rt).on_session_start("g", platform="whatsapp", conversation_id=GROUP_KEY)

        self.assertIsNone(hooks.pre_tool_call("terminal", {}, task_id="g"))
        self.assertEqual(hooks.pre_tool_call("session_search", {}, task_id="g")["action"], "block")

        out = SubCommand(rt).run("preset secret", chat)
        self.assertIn("unlock", out)
        self.assertEqual(rt.session_store.overrides[GROUP_KEY],
                         {"provider": "uzu", "model": "alibaba:qwen3.5:4b:mirai:mirai-m:4"})
        # Back to a preset without a model: the pin goes, in memory too.
        state = type("S", (), {"conversation": type("C", (), {"model_override": {"provider": "uzu"}})()})()
        rt.gateway = type("G", (), {"_peek_session_state": lambda self, key: state})()
        SubCommand(rt).run("preset project", chat)
        self.assertIsNone(rt.session_store.overrides[GROUP_KEY])
        self.assertIsNone(state.conversation.model_override)
        SubCommand(rt).run("preset secret", chat)
        self.assertEqual(hooks.pre_tool_call("terminal", {}, task_id="g")["action"], "block")
        self.assertIsNone(hooks.pre_tool_call("read_file", {}, task_id="g"))
        self.assertIsNone(hooks.pre_tool_call("zoom", {}, task_id="g"))

        self.assertTrue(rt.is_locked("vault"))
        self.assertIn("Unlocked", hooks.unlock(chat, "pass phrase"))
        self.assertFalse(rt.is_locked("vault"))
        rt.lock("vault")
        self.assertEqual(hooks.unlock(chat, "other"), "Wrong passphrase.")

        self.assertIn("main chat", SubCommand(rt).run("", P.Chat("whatsapp", "dm", "336")))


class MainTopicTest(Temp):
    def test_the_main_topic_is_the_main_chat(self):
        Runtime(self.root, {**CONFIG, "main_topics": {"telegram:123": 77}}, fake_complete)
        try:
            self.assertTrue(P.Chat.from_session_key("agent:main:telegram:dm:123:77", "telegram").is_main)
            self.assertFalse(P.Chat.from_session_key("agent:main:telegram:dm:123:78", "telegram").is_main)
            self.assertFalse(P.Chat.from_session_key("agent:main:telegram:dm:999:77", "telegram").is_main)
            # A group topic with the same number is a sub-chat still.
            self.assertFalse(P.Chat.from_session_key("agent:main:telegram:group:123:77", "telegram").is_main)
        finally:
            P.main_topics().clear()


class TelegramTopicTest(Temp):
    def test_a_dm_topic_is_a_sub_chat_with_its_own_model(self):
        rt = Runtime(self.root, CONFIG, fake_complete)
        root_key, topic_key = "agent:main:telegram:dm:123", "agent:main:telegram:dm:123:42"
        rt.session_store = FakeStore([root_key, topic_key])
        topic = P.Chat("telegram", "dm", "123", "42")
        SubCommand(rt).run("preset temp", topic)
        self.assertEqual(rt.session_store.overrides[topic_key]["provider"], "uzu")
        self.assertNotIn(root_key, rt.session_store.overrides)
        self.assertIn("main chat", SubCommand(rt).run("", P.Chat("telegram", "dm", "123")))


class GatewayHooksTest(Temp):
    def source(self, user, chat_type="group", chat_id="g3@g.us"):
        return type("Src", (), {"platform": "whatsapp", "chat_type": chat_type, "chat_id": chat_id,
                                "user_id": user, "user_id_alt": None})()

    def test_only_allowed_senders_unlock(self):
        from unii.hooks import allowed_sender

        os.environ["WHATSAPP_ALLOWED_USERS"] = "33612345678"
        try:
            self.assertTrue(allowed_sender(self.source("33612345678@s.whatsapp.net")))
            self.assertFalse(allowed_sender(self.source("4479000000@s.whatsapp.net")))
        finally:
            del os.environ["WHATSAPP_ALLOWED_USERS"]
        self.assertTrue(allowed_sender(self.source("anyone")))

    def test_a_locked_sub_chat_holds_messages_after_admission(self):
        rt = Runtime(self.root, CONFIG, fake_complete)
        hooks = Hooks(rt)
        chat = P.Chat("whatsapp", "group", "g3@g.us")
        rt.policies.set_preset(chat, "secret")
        held = hooks.post_gateway_admission(session_key=GROUP_KEY, platform="whatsapp", text="hello")
        self.assertEqual(held["action"], "handled")
        self.assertIsNone(hooks.post_gateway_admission(session_key=GROUP_KEY, platform="whatsapp", text="/sub"))
        self.assertIsNone(hooks.post_gateway_admission(session_key=MAIN_KEY, platform="whatsapp", text="hi"))


if __name__ == "__main__":
    unittest.main()
