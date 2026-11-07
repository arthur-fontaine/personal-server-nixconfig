"""cache_warm's schedule, ported from Arthur's Pi extension cache-warmer
(warmer.ts, itself the Claude Code mod cache-warmer's hooks/register.ts).
Everything Hermes-specific sits behind ``Host`` (__init__.py), so the tests
drive it with a fake clock.

After each turn the chat's prompt cache is warm. If the owner goes idle, the
last request is replayed every ``ping_interval`` (under the cache lifetime),
capped at one output token, so coming back inside the warm window costs a
cache read instead of a full re-send. It never pings a cache that has
already lapsed, stops when a ping finds it under 50 % cached, retries a
failed ping twice 5 minutes apart, and stops for the day once the shared
daily budget (full-price token equivalents) is spent. At the window's end
the Pi extension compacts a large session; Hermes' chats are compacted by
unii, not by Hermes, so here the cache is left to cool.
"""

from __future__ import annotations

import datetime as dt
import threading
from dataclasses import dataclass, field, replace
from typing import Callable, Optional, Protocol

MAX_ERRORS = 3
RETRY = 5 * 60.0
# Full-price token equivalents per token, by kind (base input price = 1).
WEIGHT = {"input": 1.0, "cache_write": 1.25, "cache_read": 0.1, "output": 5.0}


@dataclass(frozen=True)
class State:
    phase: str = "idle"  # idle active small warming cold paused stopped
    last_activity: float = 0.0
    last_ping: float = 0.0
    next_ping: float = 0.0
    pings: int = 0
    ping_tokens: int = 0
    context_tokens: int = 0
    errors: int = 0
    note: str = ""


@dataclass(frozen=True)
class Usage:
    input: int = 0
    output: int = 0
    cache_read: int = 0
    cache_write: int = 0


@dataclass(frozen=True)
class Ping:
    answered: bool
    usage: Usage = field(default_factory=Usage)
    reason: str = ""
    stop: str = ""  # ends keep-alive for this idle period instead of retrying


@dataclass(frozen=True)
class Config:
    ping_interval: float
    cache_ttl: float
    warm_window: float
    min_ping_tokens: int
    daily_budget: float


class Host(Protocol):
    def now(self) -> float: ...
    def after(self, seconds: float, run: Callable[[], None]): ...  # returns an object with cancel()
    def context_tokens(self) -> Optional[int]: ...
    def can_ping(self) -> bool: ...
    def ping(self) -> Ping: ...
    def log(self, record: dict) -> None: ...
    store: "Store"


class Store(Protocol):
    def get(self, key: str): ...
    def set(self, key: str, value) -> None: ...
    def delete(self, key: str) -> None: ...


def k(n: float) -> str:
    return f"{round(n / 1000)}k"


def span(seconds: float) -> str:
    m = max(0, round(seconds / 60))
    return f"{m}m" if m < 60 else f"{m // 60}h{m % 60:02d}"


def hhmm(t: float) -> str:
    return dt.datetime.fromtimestamp(t).strftime("%H:%M")


def date_key(t: float) -> str:
    return dt.datetime.fromtimestamp(t).strftime("%Y-%m-%d")


class Warmer:
    def __init__(self, host: Host, cfg: Config) -> None:
        self.host = host
        self.cfg = cfg
        self.s = State()
        self.timer = None
        self.lock = threading.RLock()

    # --- plumbing ---

    def _cancel(self) -> None:
        if self.timer is not None:
            self.timer.cancel()
        self.timer = None

    def _set(self, **change) -> State:
        self.s = replace(self.s, **change)
        return self.s

    def _phase(self, phase: str, note: str = "") -> None:
        self._set(phase=phase, note=note, next_ping=0.0)
        self.host.log({"event": phase, "note": note})

    def _schedule(self, delay: float) -> None:
        self._cancel()
        wait = max(0.0, delay)
        self._set(phase="warming", next_ping=self.host.now() + wait)
        self.timer = self.host.after(wait, self.tick)

    def _arm_from(self, touched: float) -> None:
        since = self.host.now() - touched
        if since >= self.cfg.cache_ttl:
            self._phase("cold", f"cache lapsed {span(since - self.cfg.cache_ttl)} ago, nothing to keep warm")
            return
        self._schedule(self.cfg.ping_interval - since)

    def _spent(self, now: float) -> float:
        return float(self.host.store.get(f"budget:{date_key(now)}") or 0)

    def _off_today(self, now: float) -> bool:
        return self.host.store.get(f"off:{date_key(now)}") is True

    # --- the schedule ---

    def tick(self) -> None:
        with self.lock:
            self.timer = None
            s = self.s
            if s.phase != "warming":
                return
            now = self.host.now()
            idle = now - s.last_activity
            since_touch = now - max(s.last_activity, s.last_ping)
            # 1. The cache already lapsed (the timer ran late): pinging would pay full price.
            if since_touch >= self.cfg.cache_ttl:
                self._phase("cold", f"cache lapsed after {span(since_touch)} untouched, not re-warmed")
                return
            # 2. The warm window is over: left to cool (no compaction from here, see the docstring).
            if idle >= self.cfg.warm_window:
                self._phase("stopped", f"{span(idle)} idle, warm window over, left to cool")
                return
            # 3. Switched off for the day, or the shared daily budget is spent.
            if self._off_today(now):
                self._phase("stopped", "off in every chat for today (/warm off all)")
                return
            spent = self._spent(now)
            if spent >= self.cfg.daily_budget:
                self._phase("stopped", f"daily keep-alive budget reached ({k(spent)} of {k(self.cfg.daily_budget)})")
                return
        # 4. Touch the cache, outside the lock: a turn may start meanwhile.
        r = self.host.ping()
        u = r.usage
        equivalents = (u.input * WEIGHT["input"] + u.cache_write * WEIGHT["cache_write"]
                       + u.cache_read * WEIGHT["cache_read"] + u.output * WEIGHT["output"])
        with self.lock:
            if equivalents > 0:
                key = f"budget:{date_key(now)}"
                self.host.store.set(key, round(self._spent(now) + equivalents))
            # A turn that started while the ping was in flight owns the state.
            if self.s.phase != "warming":
                return
            if not r.answered and r.stop:
                self._phase("stopped", r.stop)
                return
            if not r.answered:
                errors = s.errors + 1
                self._set(errors=errors, note=f"ping failed ({r.reason})")
                self.host.log({"event": "ping_failed", "reason": r.reason, "attempt": errors})
                if errors >= MAX_ERRORS:
                    self._phase("stopped", f"{errors} pings failed in a row ({r.reason})")
                    return
                self._schedule(RETRY)
                return
            total = u.input + u.cache_read + u.cache_write
            hit = u.cache_read / total if total else 0.0
            # 5. The ping found the cache cold: paid once, stop here.
            if hit < 0.5:
                self._phase("cold", f"ping at {hhmm(now)} found the cache cold ({round(hit * 100)}% served), stopped")
                return
            self._set(pings=s.pings + 1, ping_tokens=s.ping_tokens + u.cache_read, last_ping=now,
                      context_tokens=total or s.context_tokens, errors=0, note="")
            self.host.log({"event": "ping", "n": s.pings + 1, "cache_read": u.cache_read, "hit": round(hit, 3),
                           "input": u.input, "cache_write": u.cache_write, "output": u.output})
            self._schedule(self.cfg.ping_interval)

    # --- events ---

    def prompt_submitted(self) -> None:
        with self.lock:
            self._cancel()
            self._set(phase="paused" if self.s.phase == "paused" else "active", next_ping=0.0, note="")

    def turn_completed(self) -> None:
        with self.lock:
            tokens = self.host.context_tokens() or 0
            paused = self.s.phase == "paused"
            phase = "paused" if paused else "warming" if tokens >= self.cfg.min_ping_tokens else "small"
            self._set(last_activity=self.host.now(), last_ping=0.0, next_ping=0.0, pings=0, ping_tokens=0, errors=0,
                      context_tokens=tokens, note="", phase=phase)
            if phase == "warming":
                self._schedule(self.cfg.ping_interval)

    def context_changed(self) -> None:
        """The next request won't extend the one a ping would replay (a compaction)."""
        with self.lock:
            if self.s.phase != "warming":
                return
            self._cancel()
            self._set(last_ping=0.0)
            self._phase("stopped", "conversation changed since the last turn, nothing to keep warm")

    # --- /warm ---

    def status(self) -> str:
        s, c, now = self.s, self.cfg, self.host.now()
        spent, off = self._spent(now), self._off_today(now)
        lines = [
            f"cache-warmer · {s.phase}" + (f" · {s.note}" if s.note else ""),
            f"  context: {k(s.context_tokens)} tokens",
            f"  last activity: {hhmm(s.last_activity)} ({span(now - s.last_activity)} ago)" if s.last_activity
            else "  last activity: none yet",
            f"  pings this idle period: {s.pings} ({k(s.ping_tokens)} served from cache)",
        ]
        if s.phase == "warming":
            lines += [f"  next ping: {hhmm(s.next_ping)}",
                      f"  warm window ends: {hhmm(s.last_activity + c.warm_window)}, then let it cool"]
        lines += [
            f"  today's keep-alive spend: {k(spent)} of {k(c.daily_budget)} equivalents"
            + (" · off in every chat today" if off else ""),
            f"  settings: ping every {span(c.ping_interval)} · cache lifetime {span(c.cache_ttl)} · warm window "
            f"{span(c.warm_window)} · ping ≥ {k(c.min_ping_tokens)}",
            "  commands: /warm · /warm off · /warm on · /warm off all · /warm on all · /warm now",
        ]
        return "\n".join(lines)

    def _resume_here(self) -> str:
        self._set(note="")
        if not self.s.last_activity:
            self._phase("idle")
            return "cache-warmer is on for this chat. It arms after the next turn."
        tokens = self.host.context_tokens() or self.s.context_tokens
        self._set(context_tokens=tokens)
        if tokens < self.cfg.min_ping_tokens:
            self._phase("small")
            return (f"cache-warmer is on for this chat. Context is {k(tokens)}, under the "
                    f"{k(self.cfg.min_ping_tokens)} ping line, so nothing to do yet.")
        if not self.host.can_ping():
            self._phase("stopped", "nothing to keep warm yet")
            return self.status()
        self._arm_from(max(self.s.last_activity, self.s.last_ping))
        return self.status()

    def command(self, args: str) -> str:
        arg = " ".join((args or "").strip().lower().split())
        now = self.host.now()
        with self.lock:
            if arg in ("off", "pause"):
                self._cancel()
                self._phase("paused", "off for this chat (/warm off)")
                return "cache-warmer is off for this chat only. /warm on turns it back on here."
            if arg in ("on", "resume"):
                note = (" Note: /warm off all is still in effect today, so nothing will ping until /warm on all."
                        if self._off_today(now) else "")
                return self._resume_here() + note
            if arg == "off all":
                self._cancel()
                self.host.store.set(f"off:{date_key(now)}", True)
                self._phase("stopped", "off in every chat for today (/warm off all)")
                return f"cache-warmer is off in every chat for the rest of {date_key(now)}. /warm on all lifts it."
            if arg == "on all":
                self.host.store.delete(f"off:{date_key(now)}")
                return "Lifted /warm off all: every chat can warm again.\n" + self._resume_here()
            if arg == "now":
                if not self.s.last_activity:
                    return "Nothing to ping yet: no turn has completed in this chat."
                self._cancel()
                self._set(phase="warming")
        if arg == "now":
            self.tick()
        return self.status()
