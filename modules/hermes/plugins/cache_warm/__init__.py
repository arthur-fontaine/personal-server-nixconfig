"""cache_warm: keep a chat's prompt cache warm while its owner may answer.

Each step of a turn re-sends the whole prompt (docs/hermes.md, "Speed"), and
the first step of the next turn is only fast when the provider still has its
prefix cached. Claude routes get a 1-hour cache from Hermes itself
(``prompt_caching.cache_ttl: auto``, agent/model.nix); OpenAI-style caches
keep a prefix only 5 to 10 minutes after its last use, and the owner often
answers after that. So, after a turn of a person's chat (Telegram) on a
chat-completions route, this re-sends that turn's last request with
``max_tokens=1`` every ``interval`` seconds for ``window`` seconds, and stops
as soon as the chat's next request goes out. A ping prefills from the cache
(the cached-input price, a tenth or less of a cold one, and no new tokens but
one); the next turn's prefix is the same up to where the memory's view of the
last turn begins, so that much starts warm.

Not warmed: subagents, cron and events (machine-paced), routes whose cache
lasts hours anyway or that are local (``skip_providers``, loopback), and any
other API mode (Anthropic's has the 1-hour tier; Codex keeps its own
retention, agent/transports/codex.py). Each ping is logged with its usage to
``logs/cache-warm.jsonl``, to check that it pays off.

The request is captured by an ``llm_execution`` middleware, which sees the
exact provider kwargs (the hooks' copies are size-capped); it is re-sent with
the session's own client, found in the gateway's agent cache, as Hermes reads
it (gateway/run.py, _cached_agent_for_hygiene). Anything missing, the plugin
does nothing: it never touches the turn's own call.
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

logger = logging.getLogger(__name__)

PERSON_PACED = frozenset({"telegram"})
LOOPBACK = frozenset({"127.0.0.1", "localhost", "::1"})


class Warmer:
    def __init__(self, config: dict, *, log_path: Optional[Path] = None,
                 find_client: Optional[Callable[[str], Any]] = None, clock: Callable[[], float] = time.monotonic):
        self.interval = float(config.get("interval", 240))
        self.window = float(config.get("window", 900))
        self.skip = frozenset(config.get("skip_providers") or ())
        self.max_sessions = int(config.get("max_sessions", 2))
        self.log_path = log_path
        self.find_client = find_client or client_for_session
        self.clock = clock
        self.lock = threading.Lock()
        # session_id -> {"request", "until", "next", "generation"}
        self.sessions: dict[str, dict] = {}
        self.wake = threading.Event()
        self.thread: Optional[threading.Thread] = None

    def eligible(self, *, platform: str, api_mode: str, provider: str, base_url: str, request: Any) -> bool:
        if platform not in PERSON_PACED or api_mode != "chat_completions":
            return False
        if (provider or "") in self.skip or (urlparse(base_url or "").hostname or "") in LOOPBACK:
            return False
        return isinstance(request, dict) and isinstance(request.get("messages"), list)

    # llm_execution middleware: runs the call, then keeps its request.
    def middleware(self, *, request: Any, next_call: Callable, session_id: str = "", platform: str = "",
                   api_mode: str = "", provider: str = "", base_url: str = "", **_: Any) -> Any:
        with self.lock:
            # The chat is talking: its own calls keep the cache warm.
            self.sessions.pop(session_id, None)
        result = next_call(request)
        if session_id and self.eligible(platform=platform, api_mode=api_mode, provider=provider,
                                        base_url=base_url, request=request):
            self.remember(session_id, request)
        return result

    def remember(self, session_id: str, request: dict) -> None:
        # Shallow: the messages are the turn's own and are not mutated once sent.
        kept = {k: v for k, v in request.items() if k not in ("stream", "stream_options", "timeout", "http_client")}
        kept["messages"] = list(request["messages"])
        now = self.clock()
        with self.lock:
            self.sessions[session_id] = {"request": kept, "until": now + self.window, "next": now + self.interval}
            while len(self.sessions) > self.max_sessions:
                oldest = min(self.sessions, key=lambda s: self.sessions[s]["until"])
                self.sessions.pop(oldest)
        self.start()
        self.wake.set()

    def due(self) -> list[tuple[str, dict]]:
        now = self.clock()
        out = []
        with self.lock:
            for session_id, entry in list(self.sessions.items()):
                if now >= entry["until"]:
                    self.sessions.pop(session_id)
                elif now >= entry["next"]:
                    entry["next"] = now + self.interval
                    out.append((session_id, entry["request"]))
        return out

    def ping(self, session_id: str, request: dict) -> Optional[dict]:
        client = self.find_client(session_id)
        if client is None:
            return None
        body = copy.copy(request)
        body["max_completion_tokens" if "max_completion_tokens" in body else "max_tokens"] = 1
        body["stream"] = False
        started = time.time()
        try:
            response = client.chat.completions.create(**body)
            usage = getattr(response, "usage", None)
            details = getattr(usage, "prompt_tokens_details", None)
            record = {
                "prompt_tokens": getattr(usage, "prompt_tokens", None),
                "cached_tokens": getattr(details, "cached_tokens", None),
                "error": None,
            }
        except Exception as error:  # noqa: BLE001 - a failed ping only loses the warmth
            record = {"error": str(error)[:300]}
        record.update({"at": started, "seconds": round(time.time() - started, 2), "session_id": session_id,
                       "model": body.get("model")})
        self.log(record)
        return record

    def log(self, record: dict) -> None:
        if not self.log_path:
            return
        try:
            self.log_path.parent.mkdir(parents=True, exist_ok=True)
            with self.log_path.open("a") as out:
                out.write(json.dumps(record, default=str) + "\n")
        except OSError:
            pass

    def start(self) -> None:
        if self.thread and self.thread.is_alive():
            return
        self.thread = threading.Thread(target=self.run, name="cache-warm", daemon=True)
        self.thread.start()

    def run(self) -> None:
        while True:
            for session_id, request in self.due():
                with self.lock:
                    still = session_id in self.sessions
                if still:
                    self.ping(session_id, request)
            with self.lock:
                upcoming = min((e["next"] for e in self.sessions.values()), default=None)
            # Asleep until the next ping is due, or until remember() adds one.
            self.wake.wait(None if upcoming is None else max(0.05, upcoming - self.clock()))
            self.wake.clear()


def client_for_session(session_id: str) -> Any:
    """The OpenAI-style client of the gateway's cached agent for this session, or None."""
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
        if getattr(agent, "session_id", None) == session_id:
            client = getattr(agent, "client", None)
            return client if hasattr(getattr(client, "chat", None), "completions") else None
    return None


def register(ctx) -> None:
    from hermes_constants import get_hermes_home

    home = Path(get_hermes_home())
    config = json.loads((home / "cache_warm" / "config.json").read_text())
    warmer = Warmer(config, log_path=home / "logs" / "cache-warm.jsonl")
    ctx.register_middleware("llm_execution", warmer.middleware)
