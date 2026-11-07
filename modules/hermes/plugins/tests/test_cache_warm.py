"""cache_warm: the Pi extension cache-warmer's tests (warmer.test.ts,
store.test.ts) on the Python schedule, then the plugin's capture and replay
through Hermes' real plugin loader and middleware chain, with a fake clock,
fake timers and a fake client."""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

PLUGINS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PLUGINS))

from cache_warm import CacheWarm, FileStore, usage_of  # noqa: E402
from cache_warm.warmer import Config, Ping, Usage, Warmer  # noqa: E402

MIN = 60.0
T0 = 1_800_000_000.0  # a fixed day


class Clock:
    def __init__(self) -> None:
        self.t = T0
        self.timers: list = []

    def __call__(self) -> float:
        return self.t

    def timer(self, seconds, run):
        entry = {"at": self.t + seconds, "run": run, "live": True}
        self.timers.append(entry)
        return SimpleNamespace(cancel=lambda: entry.update(live=False))

    def advance(self, seconds: float) -> None:
        end = self.t + seconds
        while True:
            due = sorted((e for e in self.timers if e["live"] and e["at"] <= end), key=lambda e: e["at"])
            if not due:
                break
            e = due[0]
            e["live"] = False
            self.t = e["at"]
            e["run"]()
        self.t = end


def hit(n: int) -> Ping:
    return Ping(True, Usage(input=100, output=1, cache_read=n))


class World:
    """A chat with a scripted provider (Pi's world())."""

    def __init__(self, context: int, answers, clock=None, store=None, **cfg) -> None:
        self.clock = clock or Clock()
        self.answers = list(answers)
        self.pings = 0
        self.context = context
        self.request = True
        self.store = store or FileStore(None, self.clock)
        self.records: list = []
        self.store_data: dict = {}
        if store is None:
            data = self.store_data
            self.store.get = data.get
            self.store.set = data.__setitem__
            self.store.delete = lambda k: data.pop(k, None)
        c = dict(ping_interval=50 * MIN, cache_ttl=60 * MIN, warm_window=10 * 3600, min_ping_tokens=100_000,
                 daily_budget=2_000_000)
        c.update(cfg)
        self.w = Warmer(self, Config(**c))

    def now(self):
        return self.clock()

    def after(self, s, run):
        return self.clock.timer(s, run)

    def context_tokens(self):
        return self.context

    def can_ping(self):
        return self.request

    def ping(self):
        if not self.request:
            return Ping(False, reason="nothing-to-fork", stop="nothing to keep warm yet")
        a = self.answers[min(self.pings, len(self.answers) - 1)]
        self.pings += 1
        return a(self) if callable(a) else a

    def log(self, r):
        self.records.append(r)


def test_pings_every_50_minutes():
    w = World(600_000, [hit(600_000)])
    w.w.turn_completed()
    assert w.w.s.phase == "warming"
    w.clock.advance(49 * MIN)
    assert w.pings == 0
    w.clock.advance(1 * MIN)
    assert w.pings == 1
    w.clock.advance(100 * MIN)
    assert w.pings == 3 and w.w.s.pings == 3


def test_prompt_cancels():
    w = World(600_000, [hit(600_000)])
    w.w.turn_completed()
    w.clock.advance(10 * MIN)
    w.w.prompt_submitted()
    w.clock.advance(60 * MIN)
    assert w.pings == 0 and w.w.s.phase == "active"


def test_small_left_alone():
    w = World(40_000, [hit(40_000)])
    w.w.turn_completed()
    w.clock.advance(120 * MIN)
    assert w.pings == 0 and w.w.s.phase == "small"


def test_cold_ping_stops():
    w = World(600_000, [Ping(True, Usage(input=500_000, cache_read=100_000))])
    w.w.turn_completed()
    w.clock.advance(200 * MIN)
    assert w.pings == 1 and w.w.s.phase == "cold" and "found the cache cold (17% served)" in w.w.s.note


def test_window_end_cools():
    w = World(600_000, [hit(600_000)])
    w.w.turn_completed()
    w.clock.advance(11 * 3600)
    assert w.w.s.phase == "stopped" and "left to cool" in w.w.s.note
    assert w.pings == 11  # pings at 50, 100, ... 550 min; the tick at 600 min ends it


def test_off_on():
    w = World(600_000, [hit(600_000)])
    w.w.turn_completed()
    assert "cache-warmer · warming" in w.w.command("")
    assert "off for this chat only" in w.w.command("off")
    w.clock.advance(120 * MIN)
    assert w.pings == 0
    w.w.turn_completed()
    assert w.w.s.phase == "paused"  # survives the next turn
    w.w.command("on")
    w.clock.advance(50 * MIN)
    assert w.pings == 1


def test_off_all_shared():
    clock = Clock()
    a = World(600_000, [hit(600_000)], clock=clock)
    b = World(600_000, [hit(600_000)], clock=clock)
    b.store = a.store  # one store, two chats
    a.w.turn_completed(), b.w.turn_completed()
    a.w.command("off all")
    clock.advance(60 * MIN)
    assert a.pings == 0 and b.pings == 0 and "off in every chat" in b.w.s.note
    a.w.command("on all")
    b.w.turn_completed()
    clock.advance(50 * MIN)
    assert b.pings == 1


def test_daily_budget():
    w = World(600_000, [hit(600_000)], daily_budget=100_000)
    w.w.turn_completed()
    w.clock.advance(50 * MIN)  # ~60k equivalents
    w.clock.advance(50 * MIN)  # ~120k: over
    w.clock.advance(50 * MIN)
    assert w.pings == 2 and "daily keep-alive budget reached" in w.w.s.note


def test_retries():
    # At 50 minutes the third try would land on the cache's expiry and be skipped as lapsed.
    w = World(600_000, [Ping(False, reason="overloaded")], ping_interval=40 * MIN)
    w.w.turn_completed()
    w.clock.advance(40 * MIN)
    assert w.pings == 1 and w.w.s.phase == "warming" and w.w.s.errors == 1
    w.clock.advance(10 * MIN)
    w.clock.advance(60 * MIN)
    assert w.pings == 3 and w.w.s.phase == "stopped" and "3 pings failed in a row" in w.w.s.note


def test_nothing_to_replay():
    w = World(600_000, [hit(600_000)])
    w.w.turn_completed()
    w.request = False
    w.clock.advance(50 * MIN)
    assert w.w.s.phase == "stopped" and w.w.s.note == "nothing to keep warm yet"


def test_lapsed_cache_not_rewarmed():
    w = World(600_000, [hit(600_000)])
    w.w.turn_completed()
    # The machine slept past the timer: it fires 2 h late.
    for e in w.clock.timers:
        e["at"] += 120 * MIN
    w.clock.advance(200 * MIN)
    assert w.pings == 0 and w.w.s.phase == "cold"


def test_context_changed():
    w = World(600_000, [hit(600_000)])
    w.w.turn_completed()
    w.w.context_changed()
    w.clock.advance(60 * MIN)
    assert w.pings == 0 and "conversation changed" in w.w.s.note


def test_ping_in_flight_leaves_turn_alone():
    def slow(world):
        world.w.prompt_submitted()  # a turn starts while the ping is out
        return hit(600_000)
    w = World(600_000, [slow])
    w.w.turn_completed()
    w.clock.advance(50 * MIN)
    assert w.w.s.phase == "active" and w.w.s.pings == 0


def test_store_drops_past_days():
    d = Path(tempfile.mkdtemp())
    try:
        clock = Clock()
        s = FileStore(d / "store.json", clock)
        s.set("budget:2020-01-01", 5)
        today = __import__("cache_warm.warmer", fromlist=["date_key"]).date_key(clock())
        s.set(f"budget:{today}", 7)
        assert FileStore(d / "store.json", clock).get(f"budget:{today}") == 7
        assert s.get("budget:2020-01-01") is None
    finally:
        shutil.rmtree(d)


def test_plugin_through_hermes():
    """Loaded by Hermes, the request captured by its middleware chain, replayed with one token."""
    home = Path(tempfile.mkdtemp())
    try:
        hermes_home = home / ".hermes"
        os.environ.update(HOME=str(home), HERMES_HOME=str(hermes_home))
        shutil.copytree(PLUGINS / "cache_warm", hermes_home / "plugins" / "cache_warm")
        (hermes_home / "cache_warm").mkdir()
        (hermes_home / "cache_warm" / "config.json").write_text(json.dumps(
            {"warm_hours": 10, "min_ping_k": 1, "daily_budget_k": 2000, "skip_providers": ["deepseek"],
             "ttl_minutes": {"openrouter": 5}}))
        (hermes_home / "config.yaml").write_text(json.dumps({"plugins": {"enabled": ["cache_warm"]}}))
        from hermes_cli.middleware import run_llm_execution_middleware
        from hermes_cli.plugins import discover_plugins, get_plugin_manager

        discover_plugins(force=True)
        manager = get_plugin_manager()
        assert "cache_warm" in manager._plugins and "warm" in manager._plugin_commands
        plugin = manager._plugin_commands["warm"]["handler"].__self__
        clock = Clock()
        plugin.clock, plugin.timer, plugin.store.clock = clock, clock.timer, clock
        sent = []

        def create(**body):
            sent.append(body)
            return SimpleNamespace(usage=SimpleNamespace(prompt_tokens=5000, completion_tokens=1,
                                                         prompt_tokens_details=SimpleNamespace(cached_tokens=4900)))
        client = SimpleNamespace(chat=SimpleNamespace(completions=SimpleNamespace(create=create)))
        plugin.find_client = lambda sid, mode: client
        request = {"model": "m", "messages": [{"role": "user", "content": "hi"}], "stream": True}

        def turn(platform="telegram", provider="openrouter", api_mode="chat_completions"):
            run_llm_execution_middleware(request, lambda r: create(**r), session_id="s", platform=platform,
                                         api_mode=api_mode, provider=provider, base_url="https://x.example/v1")
            plugin.post_llm_call(session_id="s", platform=platform)
        turn()
        sent.clear()
        clock.advance(250)  # 5 min TTL → every 250 s
        assert len(sent) == 1 and sent[0]["max_tokens"] == 1 and sent[0]["stream"] is False, sent
        assert "warming" in plugin.command("", session_id="s")
        log = [json.loads(l) for l in (hermes_home / "logs" / "cache-warm.jsonl").read_text().splitlines()]
        assert any(r.get("event") == "ping" and r["cache_read"] == 4900 for r in log)
        # A compaction stops it; the next turn rearms.
        plugin.post_compaction(session_id="s")
        clock.advance(600)
        assert len(sent) == 1
        # Skipped routes and machine-paced platforms are not warmed.
        sent.clear()
        for kw in ({"provider": "deepseek"}, {"api_mode": "codex_responses"}):
            plugin.chats.clear()
            turn(**kw)
            sent.clear()
            clock.advance(3600)
            assert sent == [], kw
        assert plugin.ttl("anthropic_messages", "anthropic", "https://api.anthropic.com", request) == 3600
        assert plugin.ttl("anthropic_messages", "anthropic", "", {**request, "thinking": {"type": "enabled"}}) is None
        assert plugin.ttl("chat_completions", "x", "http://127.0.0.1:8000/v1", request) is None
        assert usage_of(SimpleNamespace(usage=SimpleNamespace(input_tokens=10, output_tokens=1, cache_read_input_tokens=90,
                                                              cache_creation_input_tokens=5))) == Usage(10, 1, 90, 5)
    finally:
        shutil.rmtree(home, ignore_errors=True)


def main() -> None:
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print("ok", name)


if __name__ == "__main__":
    main()
