"""Model usage per provider and model, by hour, from Hermes' own hooks.

Hermes keeps usage per session (state.db, session_model_usage), and the main
chat is one session that never ends, so it cannot answer "the last 24 hours".
This ledger counts each physical call as Hermes reports it: post_api_request
(the chat's calls, a fallback under its own provider and model),
api_request_error (each failed attempt), post_auxiliary_call (summaries,
review, vision, titling...). Hourly rows, kept 31 days.
"""

from __future__ import annotations

import sqlite3
import threading
import time
from pathlib import Path

WINDOWS = {"24h": 86400, "7d": 7 * 86400, "30d": 30 * 86400}
KEEP = 31 * 86400

_SCHEMA = """CREATE TABLE IF NOT EXISTS usage (
  hour INTEGER NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, aux INTEGER NOT NULL,
  calls INTEGER NOT NULL DEFAULT 0, tokens_in INTEGER NOT NULL DEFAULT 0,
  tokens_out INTEGER NOT NULL DEFAULT 0, tokens_cached INTEGER NOT NULL DEFAULT 0,
  cost_usd REAL, errors INTEGER NOT NULL DEFAULT 0, last_used REAL NOT NULL DEFAULT 0,
  PRIMARY KEY (hour, provider, model, aux))"""


def _int(value) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def tokens(usage) -> tuple[int, int, int]:
    """(prompt tokens incl. cached, output tokens, cache reads) from Hermes'
    CanonicalUsage summary (agent/api_request_hooks.py)."""
    if not isinstance(usage, dict):
        return 0, 0, 0
    cached = _int(usage.get("cache_read_tokens"))
    prompt = _int(usage.get("prompt_tokens")) or (
        _int(usage.get("input_tokens")) + cached + _int(usage.get("cache_write_tokens")))
    return prompt, _int(usage.get("output_tokens")), cached


def estimate_cost(model: str, provider: str, base_url: str, usage) -> float | None:
    if not isinstance(usage, dict):
        return None
    try:
        from agent.usage_pricing import CanonicalUsage, estimate_usage_cost

        fields = {k: _int(usage.get(k)) for k in
                  ("input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "reasoning_tokens")}
        result = estimate_usage_cost(model, CanonicalUsage(**fields), provider=provider, base_url=base_url)
        amount = getattr(result, "amount_usd", None)
        return float(amount) if amount is not None else None
    except Exception:
        return None


class Ledger:
    def __init__(self, path: Path, chain: list[dict] | None = None):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.chain = [(c.get("provider", ""), c.get("model", "")) for c in (chain or [])]
        self.lock = threading.Lock()
        self.db = sqlite3.connect(str(self.path), check_same_thread=False, isolation_level=None)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute(_SCHEMA)
        self._pruned = 0.0

    def record(self, provider: str, model: str, *, aux: bool = False, usage=None, error: bool = False,
               cost: float | None = None, now: float | None = None) -> None:
        now = time.time() if now is None else now
        hour = int(now // 3600) * 3600
        prompt, out, cached = tokens(usage)
        with self.lock:
            self.db.execute(
                """INSERT INTO usage (hour, provider, model, aux, calls, tokens_in, tokens_out, tokens_cached,
                                      cost_usd, errors, last_used)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(hour, provider, model, aux) DO UPDATE SET
                     calls = calls + excluded.calls, tokens_in = tokens_in + excluded.tokens_in,
                     tokens_out = tokens_out + excluded.tokens_out,
                     tokens_cached = tokens_cached + excluded.tokens_cached,
                     cost_usd = CASE WHEN excluded.cost_usd IS NULL THEN cost_usd
                                     ELSE COALESCE(cost_usd, 0) + excluded.cost_usd END,
                     errors = errors + excluded.errors, last_used = MAX(last_used, excluded.last_used)""",
                (hour, provider or "?", model or "?", int(aux), 0 if error else 1, prompt, out, cached,
                 cost, int(error), now))
            if now - self._pruned > 3600:
                self.db.execute("DELETE FROM usage WHERE hour < ?", (now - KEEP,))
                self._pruned = now

    def role(self, provider: str, model: str, aux: bool) -> str:
        if provider in ("uzu", "local") or provider.startswith("uzu"):
            return "local"
        if aux:
            return "background"
        if self.chain and (provider, model) == self.chain[0]:
            return "main"
        if any(p == provider and (m == model or not m) for p, m in self.chain[1:]):
            return "fallback"
        # A model the chain does not name answered the chat: the first one
        # seen is not known to be the main model, so call it a fallback
        # unless there is no chain at all.
        return "main" if not self.chain else "fallback"

    def summary(self, now: float | None = None) -> list[dict]:
        now = time.time() if now is None else now
        with self.lock:
            rows = self.db.execute(
                "SELECT hour, provider, model, aux, calls, tokens_in, tokens_out, tokens_cached, cost_usd, errors, "
                "last_used FROM usage WHERE hour >= ?", (now - WINDOWS["30d"] - 3600,)).fetchall()
        models: dict[tuple, dict] = {}
        for hour, provider, model, aux, calls, tin, tout, cached, cost, errors, last in rows:
            role = self.role(provider, model, bool(aux))
            entry = models.setdefault((provider, model, role), {
                "provider": provider, "model": model, "role": role, "last_used": 0.0,
                "windows": {w: {"calls": 0, "tokens_in": 0, "tokens_out": 0, "tokens_cached": 0,
                                "cost_usd": None, "errors": 0} for w in WINDOWS}})
            entry["last_used"] = max(entry["last_used"], last)
            for name, span in WINDOWS.items():
                # An hour row counts when its hour overlaps the window.
                if hour + 3600 <= now - span:
                    continue
                w = entry["windows"][name]
                w["calls"] += calls
                w["tokens_in"] += tin
                w["tokens_out"] += tout
                w["tokens_cached"] += cached
                w["errors"] += errors
                if cost is not None:
                    w["cost_usd"] = round((w["cost_usd"] or 0) + cost, 6)
        out = sorted(models.values(), key=lambda e: (-e["windows"]["24h"]["calls"], -e["windows"]["30d"]["calls"]))
        from .protocol import now_iso

        for entry in out:
            entry["last_used"] = now_iso(entry["last_used"]) if entry["last_used"] else None
        return out
