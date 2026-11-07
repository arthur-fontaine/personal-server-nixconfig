"""lost_turns in a real gateway, started as launchd starts it (`hermes gateway`),
against a fake Telegram Bot API and a fake model on loopback, as upstream tests
its pause notice (tests/gateway/test_native_pause_notice.py at the pinned
revision).

The server's state of 2026-11-07, replayed: a turn of the owner's is cut off
by a crash; the next gateway, without the plugin, fences it ``unknown`` and
pauses the chat, and a message the owner sends gets the "send /discard" notice
and waits. Then the gateway starts with lost_turns: the turn closes as
interrupted at boot, the waiting message runs without the owner sending
anything, and a new message is answered, with no notice.
"""

from __future__ import annotations

import json
import os
import queue
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import closing, contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs

TESTS = Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS.parent))

import lost_turns as lt  # noqa: E402

OWNER = 202
PAUSED = "This conversation is paused"
HERMES = Path(sys.executable).parent / "hermes"


class Model(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if body.get("messages"):
            self.server.requests.append(body)
        text = next((m.get("content", "") for m in reversed(body.get("messages", [])) if m["role"] == "user"), "")
        if str(text).startswith("BLOCK_STARTED"):
            self.server.blocked.set()
            self.server.release.wait(120)
        message = {"role": "assistant", "content": "ACK_" + str(text)}
        payload = json.dumps({"id": "local", "choices": [{"index": 0, "message": message, "finish_reason": "stop"}],
                              "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}}).encode()
        kind = "application/json"
        if body.get("stream"):
            payload = ("data: " + json.dumps({"id": "local", "choices": [
                {"index": 0, "delta": message, "finish_reason": "stop"}]}) + "\n\ndata: [DONE]\n\n").encode()
            kind = "text/event-stream"
        try:
            self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass


class BotAPI(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _get_updates(self, body):
        try:
            return [self.server.updates.get(timeout=.2)]
        except queue.Empty:
            return []

    def _get_me(self, body):
        return {"id": 987654321, "is_bot": True, "first_name": "Fixture", "username": "lost_turns_bot"}

    def _get_webhook_info(self, body):
        return {"url": "", "pending_update_count": 0}

    def _send_message(self, body):
        self.server.sent.append(body)
        return {"message_id": len(self.server.sent) + 1000, "date": int(time.time()),
                "chat": {"id": int(body["chat_id"]), "type": "private"}, "text": body.get("text", "")}

    _METHODS = {"getUpdates": _get_updates, "getMe": _get_me, "getWebhookInfo": _get_webhook_info,
                "sendMessage": _send_message, "editMessageText": _send_message}

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        body = json.loads(raw) if "application/json" in self.headers.get("Content-Type", "") else {
            k: v[0] for k, v in parse_qs(raw.decode()).items()}
        handler = self._METHODS.get(self.path.rsplit("/", 1)[-1])
        payload = json.dumps({"ok": True, "result": handler(self, body) if handler else True}).encode()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass


def serve(handler):
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def wait_for(predicate, detail, timeout=90.0):
    deadline = time.monotonic() + timeout
    while not predicate():
        assert time.monotonic() < deadline, detail()
        time.sleep(.05)


def identify(home):
    """The gateway's control socket (gateway/control_socket.py); None until it answers."""
    pointer = home / "gateway.sock.path"
    path = pointer.read_text().strip() if pointer.exists() else str(home / "gateway.sock")
    request = json.dumps({"protocol": 1, "id": 1, "verb": "identify", "params": {}}).encode() + b"\n"
    try:
        with socket.socket(socket.AF_UNIX) as peer:
            peer.settimeout(2)
            peer.connect(path)
            peer.sendall(request)
            with peer.makefile("rb") as stream:
                reply = json.loads(stream.readline())
    except (OSError, ValueError):
        return None
    return reply.get("result") if reply.get("ok") else None


@contextmanager
def gateway(home, env, name, diagnostic):
    with (home / f"{name}.log").open("w") as log:
        proc = subprocess.Popen([sys.executable, "-I", str(HERMES), "gateway", "run"], env=env,
                                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        try:
            wait_for(lambda: proc.poll() is None and (identify(home) or {}).get("state") == "ready",
                     lambda: f"{name} never got ready\n" + diagnostic(), timeout=180)
            yield proc
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=20)


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        run(Path(tmp))
    print("ok test_a_crash_no_longer_pauses_the_owners_chat")


def run(tmp: Path) -> None:
    home, user = tmp / "state", tmp / "user"
    home.mkdir(mode=0o700)
    user.mkdir()
    shutil.copytree(TESTS.parent / "lost_turns", home / "plugins" / "lost_turns",
                    ignore=shutil.ignore_patterns("__pycache__"))
    model, bot = serve(Model), serve(BotAPI)
    model.requests, model.blocked, model.release = [], threading.Event(), threading.Event()
    bot.sent, bot.updates = [], queue.Queue()
    base = f"http://127.0.0.1:{model.server_port}/v1"

    def configure(plugins):
        (home / "config.yaml").write_text(json.dumps({
            "model": {"provider": "custom", "default": "loopback", "base_url": base},
            "gateway": {"multiplex_profiles": False},
            "platforms": {"telegram": {"enabled": True, "extra": {
                "base_url": f"http://127.0.0.1:{bot.server_port}/bot", "dm_policy": "allowlist",
                "drop_pending_on_cold_boot": False}}},
            # As on the server, an `auxiliary` section: gateway.run's import then
            # waits for the plugins (tests/lost_turns_startup.py).
            "auxiliary": {"title_generation": {"enabled": False}},
            "platform_toolsets": {"telegram": []}, "terminal": {"cwd": str(home)},
            "plugins": {"enabled": plugins, "load_timeout_seconds": 20,
                        "entries": {"lost_turns": {"allow_gateway_injection": True}}},
        }))

    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(user), "HERMES_HOME": str(home),
           "OPENAI_API_KEY": "loopback-only", "OPENAI_BASE_URL": base, "PYTHONUNBUFFERED": "1",
           "TELEGRAM_BOT_TOKEN": "987654321:loopback-fixture", "TELEGRAM_ALLOWED_USERS": str(OWNER)}
    if "SSL_CERT_FILE" in os.environ:
        env["SSL_CERT_FILE"] = os.environ["SSL_CERT_FILE"]

    def rows():
        if not (home / "state.db").exists():
            return {}
        with closing(sqlite3.connect(f"file:{home / 'state.db'}?mode=ro", uri=True)) as db:
            return {json.loads(payload).get("text"): (status, outcome) for status, outcome, payload in db.execute(
                "SELECT status, outcome, payload_json FROM session_admissions ORDER BY seq")}

    def texts():
        # Telegram MarkdownV2 escapes; compare on the unescaped text.
        return [m.get("text", "").replace("\\", "") for m in bot.sent]

    def diagnostic():
        logs = "\n".join(f"== {p.name}\n" + p.read_text(errors="replace")[-6000:]
                         for p in sorted(home.glob("*.log")) + sorted((home / "logs").glob("*.log")))
        return f"{rows()!r}\n{texts()!r}\n{logs}"

    update_id = 0

    def push(text):
        nonlocal update_id
        update_id += 1
        bot.updates.put({"update_id": update_id, "message": {
            "message_id": update_id, "date": int(time.time()),
            "chat": {"id": OWNER, "type": "private", "first_name": "Owner"},
            "from": {"id": OWNER, "is_bot": False, "first_name": "Owner"}, "text": text}})

    try:
        # A turn of the owner's, cut off by a crash.
        configure([])
        with gateway(home, env, "crash", diagnostic) as proc:
            # The first message ever carries an onboarding note: get it out of the way.
            push("WARM")
            wait_for(lambda: rows().get("WARM", ("",))[0] == "terminal", diagnostic)
            push("BLOCK_STARTED")
            wait_for(lambda: rows().get("BLOCK_STARTED", ("",))[0] == "started", diagnostic)
            assert model.blocked.wait(60), diagnostic()
            proc.kill()
        model.release.set()
        # Without the plugin: paused, and the owner is asked for /discard.
        with gateway(home, env, "paused", diagnostic):
            assert rows()["BLOCK_STARTED"] == ("unknown", None), diagnostic()
            push("AFTER_CRASH")
            wait_for(lambda: rows().get("AFTER_CRASH", ("",))[0] == "queued", diagnostic)
            wait_for(lambda: any(PAUSED in t for t in texts()), diagnostic)
        # With it, as on the server after the rebuild.
        configure(["lost_turns"])
        before = len(bot.sent)
        with gateway(home, env, "settled", diagnostic):
            wait_for(lambda: rows().get("AFTER_CRASH", ("",))[0] == "terminal"
                     and any("ACK_AFTER_CRASH" in t for t in texts()[before:]), diagnostic)
            assert rows()["BLOCK_STARTED"] == ("terminal", "interrupted"), diagnostic()
            push("AFTER_RESTART")
            wait_for(lambda: rows().get("AFTER_RESTART", ("",))[0] == "terminal"
                     and any("ACK_AFTER_RESTART" in t for t in texts()[before:]), diagnostic)
            assert not any(PAUSED in t for t in texts()[before:]), diagnostic()
        log = (home / "logs" / "agent.log").read_text(errors="replace")
        assert "Failed to load plugin 'lost_turns'" not in log, diagnostic()
        asked = [str(next((m.get("content") for m in reversed(r["messages"]) if m["role"] == "user"), ""))
                 for r in model.requests]
        assert sum(a.startswith("BLOCK_STARTED") for a in asked) == 1, asked  # never replayed
        # The turn that ran next knew the previous one had been cut off.
        after = next(r for r, a in zip(model.requests, asked) if a.startswith("AFTER_CRASH"))
        assert any(lt.NOTICE in str(m.get("content")) for m in after["messages"]), after["messages"]
    finally:
        model.release.set()
        for server in (model, bot):
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
