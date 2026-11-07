"""The cache_warm plugin: a person's chat stays warm between turns, nothing else.

A fake OpenAI-style client stands for the session's agent's; the clock is the
test's. Run from the plugins directory, as checks/default.nix does.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from cache_warm import Warmer  # noqa: E402


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class Client:
    def __init__(self, fail: bool = False):
        self.calls: list[dict] = []
        self.fail = fail
        self.chat = SimpleNamespace(completions=SimpleNamespace(create=self.create))

    def create(self, **body):
        self.calls.append(body)
        if self.fail:
            raise RuntimeError("429 rate limited")
        usage = SimpleNamespace(prompt_tokens=70000, prompt_tokens_details=SimpleNamespace(cached_tokens=69888))
        return SimpleNamespace(usage=usage)


def check(name: str, got, want) -> None:
    if got != want:
        raise AssertionError(f"{name}: got {got!r}, want {want!r}")
    print(f"ok  {name}")


REQUEST = {"model": "gpt-x", "messages": [{"role": "system", "content": "S"}, {"role": "user", "content": "hi"}],
           "tools": [{"type": "function", "function": {"name": "t"}}], "stream": True,
           "stream_options": {"include_usage": True}, "max_tokens": 4096}
TELEGRAM = {"platform": "telegram", "api_mode": "chat_completions", "provider": "openrouter",
            "base_url": "https://openrouter.ai/api/v1"}


def turn(warmer: Warmer, session: str = "s1", **context) -> None:
    warmer.middleware(request=dict(REQUEST), next_call=lambda r: "answer", session_id=session, **{**TELEGRAM, **context})


def main() -> None:
    scratch = Path(tempfile.mkdtemp(dir=os.environ.get("TMPDIR") or None))
    clock = Clock()
    client = Client()
    log = scratch / "cache-warm.jsonl"
    warmer = Warmer({"interval": 240, "window": 900, "skip_providers": ["deepseek", "uzu"]},
                    log_path=log, find_client=lambda s: client, clock=clock)
    warmer.start = lambda: None  # driven by hand: due() and ping()

    check("the call itself goes through", warmer.middleware(request=dict(REQUEST), next_call=lambda r: "answer",
                                                            session_id="s1", **TELEGRAM), "answer")
    check("nothing due at once", warmer.due(), [])
    clock.now += 240
    due = warmer.due()
    check("due after the interval", [s for s, _ in due], ["s1"])
    record = warmer.ping(*due[0])
    body = client.calls[-1]
    check("the same prefix: messages and tools", (body["messages"], body["tools"]), (REQUEST["messages"], REQUEST["tools"]))
    check("one token, not streamed", (body["max_tokens"], body["stream"], "stream_options" in body), (1, False, False))
    check("its usage is logged", (record["cached_tokens"], json.loads(log.read_text().splitlines()[-1])["cached_tokens"]),
          (69888, 69888))

    clock.now += 240
    check("again after another interval", [s for s, _ in warmer.due()], ["s1"])
    clock.now += 500
    check("not past the window", warmer.due(), [])
    check("forgotten after the window", warmer.sessions, {})

    turn(warmer)
    clock.now += 100
    turn(warmer)  # the next turn's call: the window starts again from it
    clock.now += 200
    check("a new call resets the timer", warmer.due(), [])
    clock.now += 40
    check("then due from the last call", [s for s, _ in warmer.due()], ["s1"])

    # During the call itself, the chat is not warmed (its own call does it).
    seen = {}
    def during(request):
        seen["sessions"] = dict(warmer.sessions)
        return "answer"
    warmer.middleware(request=dict(REQUEST), next_call=during, session_id="s1", **TELEGRAM)
    check("not warmed while the chat calls", "s1" in seen["sessions"], False)

    fresh = lambda: Warmer({"skip_providers": ["deepseek", "uzu"]}, find_client=lambda s: client, clock=clock)
    for name, context in [
        ("a subagent or cron (not telegram)", {"platform": "cron"}),
        ("Anthropic's API mode", {"api_mode": "anthropic_messages"}),
        ("Codex", {"api_mode": "codex_responses"}),
        ("a skipped provider", {"provider": "deepseek"}),
        ("a local model", {"provider": "custom", "base_url": "http://127.0.0.1:8000/v1"}),
    ]:
        w = fresh()
        w.start = lambda: None
        turn(w, **context)
        check(f"not warmed: {name}", w.sessions, {})

    w = Warmer({"max_sessions": 2}, find_client=lambda s: client, clock=clock)
    w.start = lambda: None
    for session in ("a", "b", "c"):
        clock.now += 1
        turn(w, session=session)
    check("at most max_sessions chats", sorted(w.sessions), ["b", "c"])

    failing = Warmer({}, find_client=lambda s: Client(fail=True), clock=clock, log_path=log)
    check("a failed ping is logged, not raised", "429" in failing.ping("s1", dict(REQUEST))["error"], True)
    gone = Warmer({}, find_client=lambda s: None, clock=clock)
    check("no agent: no ping", gone.ping("s1", dict(REQUEST)), None)

    # The real thread: a short interval pings by itself, then stops after the window.
    live_client = Client()
    live = Warmer({"interval": 0.2, "window": 0.7}, find_client=lambda s: live_client)
    turn(live)
    deadline = time.monotonic() + 5
    while len(live_client.calls) < 2 and time.monotonic() < deadline:
        time.sleep(0.05)
    check("the thread pings by itself", len(live_client.calls) >= 2, True)
    time.sleep(1.0)
    settled = len(live_client.calls)
    time.sleep(0.5)
    check("and stops after the window", len(live_client.calls), settled)


if __name__ == "__main__":
    main()
