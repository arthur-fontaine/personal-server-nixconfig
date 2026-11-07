"""app_topic in a real gateway (`hermes gateway run`), against a fake Telegram
Bot API and a fake model on loopback, as test_lost_turns_gateway.py does: the
plugin loads, wraps Hermes' own Telegram adapter, creates the App topic and
its slot messages, follows a reply with a spoken `notify`, and answers a
request posted in the topic without the model ever seeing it.
"""

from __future__ import annotations

import json
import os
import queue
import shutil
import sys
import tempfile
import time
from pathlib import Path

TESTS = Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS))

from test_lost_turns_gateway import BotAPI, Model, gateway, serve, wait_for  # noqa: E402

OWNER = 202
THREAD = 77


class AppBotAPI(BotAPI):
    def _create_forum_topic(self, body):
        self.server.topics += 1
        return {"message_thread_id": THREAD, "name": body.get("name", ""), "icon_color": 7322096}

    def _delete_message(self, body):
        self.server.deleted.append(int(body.get("message_id", 0)))
        return True

    def _send_message(self, body):
        self.server.sent.append(body)
        body["_id"] = len(self.server.sent) + 1000
        chat = int(body.get("chat_id") or OWNER)
        return {"message_id": body["_id"], "date": int(time.time()),
                "chat": {"id": chat, "type": "private"}, "text": body.get("text", "")}

    def _edit_message_text(self, body):
        # An edit changes the message it names, in its topic.
        for message in self.server.sent:
            if str(message.get("_id")) == str(body.get("message_id")):
                message["text"] = body.get("text", "")
        return True

    _METHODS = {**BotAPI._METHODS, "createForumTopic": _create_forum_topic, "deleteMessage": _delete_message,
                "sendMessage": _send_message, "editMessageText": _edit_message_text, "sendDocument": _send_message}


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        run(Path(tmp))
    print("ok test_app_topic_in_a_real_gateway")


def run(tmp: Path) -> None:
    home, user = tmp / "state", tmp / "user"
    home.mkdir(mode=0o700)
    user.mkdir()
    shutil.copytree(TESTS.parent / "app_topic", home / "plugins" / "app_topic",
                    ignore=shutil.ignore_patterns("__pycache__"))
    (home / "app_topic").mkdir()
    (home / "app_topic" / "config.json").write_text(json.dumps({"chain": [{"provider": "custom", "model": "loopback"}]}))
    model, bot = serve(Model), serve(AppBotAPI)
    model.requests, model.blocked, model.release = [], __import__("threading").Event(), __import__("threading").Event()
    model.release.set()
    bot.sent, bot.updates, bot.topics, bot.deleted = [], queue.Queue(), 0, []
    base = f"http://127.0.0.1:{model.server_port}/v1"
    (home / "config.yaml").write_text(json.dumps({
        "model": {"provider": "custom", "default": "loopback", "base_url": base},
        "gateway": {"multiplex_profiles": False},
        "platforms": {"telegram": {"enabled": True, "extra": {
            "base_url": f"http://127.0.0.1:{bot.server_port}/bot", "dm_policy": "allowlist",
            "drop_pending_on_cold_boot": False}}},
        "auxiliary": {"title_generation": {"enabled": False}},
        "streaming": {"enabled": False},
        "platform_toolsets": {"telegram": []}, "terminal": {"cwd": str(home)},
        "plugins": {"enabled": ["app_topic"], "load_timeout_seconds": 20,
                    "entries": {"app_topic": {"allow_gateway_injection": True}}},
    }))
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(user), "HERMES_HOME": str(home),
           "OPENAI_API_KEY": "loopback-only", "OPENAI_BASE_URL": base, "PYTHONUNBUFFERED": "1",
           "TELEGRAM_BOT_TOKEN": "987654321:loopback-fixture", "TELEGRAM_ALLOWED_USERS": str(OWNER)}
    if "SSL_CERT_FILE" in os.environ:
        env["SSL_CERT_FILE"] = os.environ["SSL_CERT_FILE"]

    def topic(type_):
        out = []
        for m in bot.sent:
            if str(m.get("message_thread_id")) != str(THREAD) or "text" not in m:
                continue
            text = m["text"].replace("<pre><code class=\"language-json\">", "").replace("</code></pre>", "")
            text = text.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
            try:
                obj = json.loads(text)
            except ValueError:
                continue
            if obj.get("type") == type_:
                out.append(obj)
        return out

    def diagnostic():
        logs = "\n".join(f"== {p.name}\n" + p.read_text(errors="replace")[-6000:]
                         for p in sorted(home.glob("*.log")) + sorted((home / "logs").glob("*.log")))
        return f"{bot.sent!r}\n{logs}"

    update_id = 0

    def push(text, thread=None):
        nonlocal update_id
        update_id += 1
        message = {"message_id": 500 + update_id, "date": int(time.time()),
                   "chat": {"id": OWNER, "type": "private", "first_name": "Owner"},
                   "from": {"id": OWNER, "is_bot": False, "first_name": "Owner"}, "text": text}
        if thread is not None:
            message.update(message_thread_id=thread, is_topic_message=True)
        bot.updates.put({"update_id": update_id, "message": message})

    def asked():
        return [str(next((m.get("content") for m in reversed(r["messages"]) if m["role"] == "user"), ""))
                for r in model.requests]

    try:
        with gateway(home, env, "app", diagnostic):
            wait_for(lambda: bot.topics == 1 and topic("state") and topic("stats") and topic("devices"), diagnostic)
            assert all(m.get("disable_notification") in (True, "true", "True") for m in bot.sent
                       if str(m.get("message_thread_id")) == str(THREAD)), diagnostic()
            # The owner writes in the main chat: Hermes answers, the app gets its spoken text.
            push("WARM")
            wait_for(lambda: any(n["spoken"].startswith("ACK_WARM") for n in topic("notify")), diagnostic)
            note = next(n for n in topic("notify") if n["spoken"].startswith("ACK_WARM"))
            assert not any("no_home_channel" in n["body"] or "nohomechannel" in n["body"] for n in topic("notify")), topic("notify")
            assert note["chat"] == 0 and note["kind"] == "message", note
            # A request in the App topic: answered there, deleted, and never a turn.
            push(json.dumps({"v": 1, "type": "pet.feed"}), thread=THREAD)
            wait_for(lambda: topic("reply"), diagnostic)
            reply = topic("reply")[-1]
            assert reply["ok"] is False and reply["error"]["code"] == "unavailable", reply
            wait_for(lambda: reply["re"] in bot.deleted, diagnostic)
            push(json.dumps({"v": 1, "type": "stats.refresh"}), thread=THREAD)
            wait_for(lambda: len(topic("reply")) == 2, diagnostic)
            time.sleep(1)
            assert not any("pet.feed" in a or "stats.refresh" in a for a in asked()), asked()
            # The model's calls are in the usage stats.
            wait_for(lambda: any(m["model"] == "loopback" for m in topic("stats")[-1]["models"]), diagnostic)
        log = (home / "logs" / "agent.log").read_text(errors="replace")
        assert "Failed to load plugin 'app_topic'" not in log, diagnostic()
        assert "the Telegram adapter changed" not in log, diagnostic()
    finally:
        for server in (model, bot):
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
