"""cache_warm: keep an idle chat's prompt cache warm, Arthur's Pi extension
cache-warmer's algorithm (warmer.py) on Hermes.

After a turn of a person's chat (Telegram) whose prompt is at least
``min_ping_k`` thousand tokens, the turn's last request is replayed with one
output token before the provider's cache lifetime runs out, for up to
``warm_hours`` of idleness, through the session's own client. Its interval
comes from that route's cache lifetime, as the Pi extension pairs them (60
minutes → every 50, 5 → every 4: five sixths of it):

- Anthropic Messages: Hermes asks the 1-hour tier for person-paced chats
  (``prompt_caching.cache_ttl: auto``, agent/cache-warm.nix): 60 minutes.
- Chat Completions (OpenAI-style): ``ttl_minutes`` per provider, else 5.
- Not warmed: Codex Responses (its own retention), loopback (the local
  model), providers in ``skip_providers`` (DeepSeek's disk cache lasts
  hours), a request whose Anthropic thinking takes its budget from
  max_tokens (Pi's own rule), subagents, cron and events.

The request is captured by an ``llm_execution`` middleware (the hooks' copies
are size-capped); the chat's next request cancels any pending ping. A
compaction (``post_compaction``) means the next request will not extend the
captured one: pinging stops. At the window's end the Pi extension compacts;
Hermes' main chat is compacted by unii, never by Hermes, so the cache is left
to cool. ``/warm`` (status, off, on, off all, on all, now) as in Pi. Pings and
their usage go to ``logs/cache-warm.jsonl``.
"""

from __future__ import annotations

import copy
import json
import logging
import sys
import threading
import time
from pathlib import Path
from typing import Any, Callable, Optional
from urllib.parse import urlparse

from .warmer import Config, Ping, Usage, Warmer, date_key

logger = logging.getLogger(__name__)

PERSON_PACED = frozenset({"telegram"})
LOOPBACK = frozenset({"127.0.0.1", "localhost", "::1"})
ANTHROPIC_TTL_MINUTES = 60
DEFAULT_TTL_MINUTES = 5


def usage_of(response: Any) -> Usage:
    """Token buckets of an OpenAI-style or Anthropic response."""
    u = getattr(response, "usage", None)
    if u is None:
        return Usage()
    if getattr(u, "prompt_tokens", None) is not None:
        details = getattr(u, "prompt_tokens_details", None)
        cached = int(getattr(details, "cached_tokens", 0) or 0)
        return Usage(input=int(u.prompt_tokens) - cached, output=int(getattr(u, "completion_tokens", 0) or 0),
                     cache_read=cached)
    return Usage(input=int(getattr(u, "input_tokens", 0) or 0), output=int(getattr(u, "output_tokens", 0) or 0),
                 cache_read=int(getattr(u, "cache_read_input_tokens", 0) or 0),
                 cache_write=int(getattr(u, "cache_creation_input_tokens", 0) or 0))


class FileStore:
    """The daily budget and /warm off all, shared by every chat (Pi's store.ts):
    only today's and yesterday's keys are kept."""

    def __init__(self, path: Optional[Path], clock: Callable[[], float] = time.time) -> None:
        self.path, self.clock, self.lock = path, clock, threading.Lock()

    def _load(self) -> dict:
        try:
            data = json.loads(self.path.read_text()) if self.path else {}
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def get(self, key: str):
        with self.lock:
            return self._load().get(key)

    def _change(self, apply: Callable[[dict], None]) -> None:
        with self.lock:
            now = self.clock()
            keep = {date_key(now), date_key(now - 86400)}
            data = {k: v for k, v in self._load().items() if k.split(":", 1)[-1] in keep}
            apply(data)
            if self.path:
                self.path.parent.mkdir(parents=True, exist_ok=True)
                tmp = self.path.with_suffix(".tmp")
                tmp.write_text(json.dumps(data, indent=2))
                tmp.replace(self.path)

    def set(self, key: str, value) -> None:
        self._change(lambda d: d.__setitem__(key, value))

    def delete(self, key: str) -> None:
        self._change(lambda d: d.pop(key, None))


class _Timer:
    def __init__(self, seconds: float, run: Callable[[], None]) -> None:
        self.t = threading.Timer(seconds, run)
        self.t.daemon = True
        self.t.start()

    def cancel(self) -> None:
        self.t.cancel()


class Chat:
    """One chat's Host: its captured request and the client that replays it."""

    def __init__(self, plugin: "CacheWarm", session_id: str) -> None:
        self.plugin, self.session_id = plugin, session_id
        self.request: Optional[dict] = None
        self.api_mode = ""
        self.tokens: Optional[int] = None
        self.store = plugin.store
        self.warmer: Optional[Warmer] = None
        self.ttl = 0.0

    def now(self) -> float:
        return self.plugin.clock()

    def after(self, seconds: float, run: Callable[[], None]):
        return self.plugin.timer(seconds, run)

    def context_tokens(self) -> Optional[int]:
        return self.tokens

    def can_ping(self) -> bool:
        return self.request is not None

    def log(self, record: dict) -> None:
        self.plugin.log({"session_id": self.session_id, **record})

    def ping(self) -> Ping:
        if self.request is None:
            return Ping(False, reason="nothing-to-fork", stop="nothing to keep warm yet")
        client = self.plugin.find_client(self.session_id, self.api_mode)
        if client is None:
            return Ping(False, reason="no-client", stop="the chat's client is gone (gateway restarted)")
        body = copy.copy(self.request)
        for key in ("stream", "stream_options", "timeout", "http_client"):
            body.pop(key, None)
        started = time.time()
        try:
            if self.api_mode == "anthropic_messages":
                body["max_tokens"] = 1
                response = client.messages.create(**body)
            else:
                body["max_completion_tokens" if "max_completion_tokens" in body else "max_tokens"] = 1
                response = client.chat.completions.create(**body, stream=False)
        except Exception as error:  # noqa: BLE001 - a failed ping only loses the warmth
            self.log({"event": "ping_error", "error": str(error)[:300], "seconds": round(time.time() - started, 2)})
            return Ping(False, reason=str(error)[:200])
        return Ping(True, usage_of(response))


class CacheWarm:
    def __init__(self, config: dict, *, log_path: Optional[Path] = None, store_path: Optional[Path] = None,
                 find_client: Optional[Callable] = None, clock: Callable[[], float] = time.time,
                 timer: Callable = _Timer) -> None:
        self.ping_fraction = 5 / 6
        self.warm_window = float(config.get("warm_hours", 10)) * 3600
        self.min_tokens = int(config.get("min_ping_k", 32)) * 1000
        self.budget = float(config.get("daily_budget_k", 2000)) * 1000
        self.ttl_minutes = {str(k): float(v) for k, v in (config.get("ttl_minutes") or {}).items()}
        self.skip = frozenset(config.get("skip_providers") or ())
        self.log_path = log_path
        self.store = FileStore(store_path, clock)
        self.find_client = find_client or client_for_session
        self.clock = clock
        self.timer = timer
        self.chats: dict = {}
        self.lock = threading.Lock()

    def log(self, record: dict) -> None:
        if not self.log_path:
            return
        try:
            self.log_path.parent.mkdir(parents=True, exist_ok=True)
            with self.log_path.open("a") as out:
                out.write(json.dumps({"at": self.clock(), **record}, default=str) + "\n")
        except OSError:
            pass

    def ttl(self, api_mode: str, provider: str, base_url: str, request: Any) -> Optional[float]:
        """The route's cache lifetime in seconds, or None when it is not warmed."""
        if (provider or "") in self.skip or (urlparse(base_url or "").hostname or "") in LOOPBACK:
            return None
        if not isinstance(request, dict) or not isinstance(request.get("messages"), list):
            return None
        if api_mode == "anthropic_messages":
            thinking = request.get("thinking") or {}
            if isinstance(thinking, dict) and thinking.get("type") == "enabled":
                return None  # budget thinking: a one-token replay would be another request
            return ANTHROPIC_TTL_MINUTES * 60
        if api_mode == "chat_completions":
            return self.ttl_minutes.get(provider or "", DEFAULT_TTL_MINUTES) * 60
        return None

    def chat(self, session_id: str) -> Chat:
        with self.lock:
            chat = self.chats.get(session_id)
            if chat is None:
                chat = self.chats[session_id] = Chat(self, session_id)
            return chat

    def _warmer(self, chat: Chat, ttl: float) -> Warmer:
        if chat.warmer is None or chat.ttl != ttl:
            cfg = Config(ping_interval=ttl * self.ping_fraction, cache_ttl=ttl, warm_window=self.warm_window,
                         min_ping_tokens=self.min_tokens, daily_budget=self.budget)
            old = chat.warmer
            chat.warmer, chat.ttl = Warmer(chat, cfg), ttl
            if old is not None:
                old.prompt_submitted()
                chat.warmer.s = old.s
        return chat.warmer

    # llm_execution middleware: runs the call, then keeps its request.
    def middleware(self, *, request: Any, next_call: Callable, session_id: str = "", platform: str = "",
                   api_mode: str = "", provider: str = "", base_url: str = "", **_: Any) -> Any:
        chat = self.chats.get(session_id)
        if chat is not None and chat.warmer is not None:
            chat.warmer.prompt_submitted()  # the chat is talking: its own calls keep the cache warm
        result = next_call(request)
        if not session_id or platform not in PERSON_PACED:
            return result
        ttl = self.ttl(api_mode, provider, base_url, request)
        chat = self.chat(session_id)
        if ttl is None:
            chat.request = None
            return result
        kept = {k: v for k, v in request.items() if k not in ("stream", "stream_options", "timeout", "http_client")}
        kept["messages"] = list(request["messages"])
        chat.request, chat.api_mode = kept, api_mode
        u = usage_of(result)
        tokens = u.input + u.cache_read + u.cache_write
        chat.tokens = tokens or chat.tokens
        self._warmer(chat, ttl)
        return result

    def pre_llm_call(self, session_id: str = "", **_: Any) -> None:
        chat = self.chats.get(session_id or "")
        if chat is not None and chat.warmer is not None:
            chat.warmer.prompt_submitted()

    def post_llm_call(self, session_id: str = "", platform: str = "", **_: Any) -> None:
        chat = self.chats.get(session_id or "")
        if chat is None or chat.warmer is None or platform not in PERSON_PACED:
            return
        if chat.request is None:
            return
        chat.warmer.turn_completed()

    def post_compaction(self, session_id: str = "", **_: Any) -> None:
        chat = self.chats.get(session_id or "")
        if chat is not None:
            chat.request = None
            if chat.warmer is not None:
                chat.warmer.context_changed()

    def command(self, raw_args: str = "", session_id: str = "", **_: Any) -> str:
        chat = self.chats.get(session_id or "")
        if chat is None or chat.warmer is None:
            # The command may come from another surface: the chat warmed last.
            warmed = [c for c in self.chats.values() if c.warmer is not None]
            chat = max(warmed, key=lambda c: c.warmer.s.last_activity, default=None)
        if chat is None:
            return "cache-warmer: no chat has a request to keep warm yet. It arms after a turn."
        return chat.warmer.command(raw_args)


def client_for_session(session_id: str, api_mode: str) -> Any:
    """The client of the gateway's cached agent for this session, or None."""
    # Never an import: owner_approval's _gateway_loop says why.
    ref = getattr(sys.modules.get("gateway.run"), "_gateway_runner_ref", None)
    try:
        runner = ref() if callable(ref) else None
    except Exception:  # noqa: BLE001
        return None
    cache = getattr(runner, "_agent_cache", None)
    if not cache:
        return None
    lock = getattr(runner, "_agent_cache_lock", None)
    try:
        if lock:
            with lock:
                entries = list(cache.values())
        else:
            entries = list(cache.values())
    except Exception:  # noqa: BLE001
        return None
    for entry in entries:
        agent = entry[0] if isinstance(entry, tuple) and entry else entry
        if getattr(agent, "session_id", None) != session_id:
            continue
        if api_mode == "anthropic_messages":
            client = getattr(agent, "_anthropic_client", None)
            return client if hasattr(client, "messages") else None
        client = getattr(agent, "client", None)
        return client if hasattr(getattr(client, "chat", None), "completions") else None
    return None


def register(ctx) -> None:
    from hermes_constants import get_hermes_home

    home = Path(get_hermes_home())
    config = json.loads((home / "cache_warm" / "config.json").read_text())
    plugin = CacheWarm(config, log_path=home / "logs" / "cache-warm.jsonl", store_path=home / "cache_warm" / "store.json")
    ctx.register_middleware("llm_execution", plugin.middleware)
    ctx.register_hook("pre_llm_call", plugin.pre_llm_call)
    ctx.register_hook("post_llm_call", plugin.post_llm_call)
    ctx.register_hook("post_compaction", plugin.post_compaction)
    ctx.register_command("warm", plugin.command, description="Cache warmer: status, off/on, off all/on all, now",
                         args_hint="[off|on|off all|on all|now]")
