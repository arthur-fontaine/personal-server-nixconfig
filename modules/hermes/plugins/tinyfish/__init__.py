"""tinyfish: TinyFish Search (https://docs.tinyfish.ai/search-api) as a web
search provider, selected by ``web.search_backend: tinyfish``
(agent/tools.nix). Search only: ``web_extract`` keeps its own backend.

Hermes' pinned revision has no TinyFish backend; this follows the shape of its
bundled ones (plugins/web/brave_free/provider.py), through the same registrar
(PluginContext.register_web_search_provider). A failed call is retried once on
Hermes' keyless ring (``web.keyless_rescue``), so a missing or revoked key
degrades search instead of breaking it.
"""

from __future__ import annotations

import logging
from typing import Any

logger = logging.getLogger(__name__)

ENDPOINT = "https://api.search.tinyfish.ai"
KEY_ENV = "TINYFISH_API_KEY"
# TinyFish returns 10 results a page; Hermes asks for 5 by default.
MAX_RESULTS = 10


def rows(data: dict, limit: int) -> list[dict[str, Any]]:
    from plugins.web._common import title_hit

    results = (data or {}).get("results") or []
    return [
        title_hit(str(r.get("title", "")), str(r.get("url", "")), str(r.get("snippet", "")), i + 1)
        for i, r in enumerate(results[:limit])
    ]


def make_provider():
    from plugins.web._common import (
        BaseWebSearchProvider, http_get_json, provider_env, run_search, search_fail, search_ok, setup_schema,
    )

    class TinyFishWebSearchProvider(BaseWebSearchProvider):
        NAME = "tinyfish"
        DISPLAY_NAME = "TinyFish Search"
        KEY_ENV = KEY_ENV

        def search(self, query: str, limit: int = 5) -> dict[str, Any]:
            api_key = provider_env(KEY_ENV)
            if not api_key:
                return search_fail(f"{KEY_ENV} is not set")
            limit = max(1, min(int(limit), MAX_RESULTS))

            def body() -> dict[str, Any]:
                data, failure = http_get_json(
                    "TinyFish Search", ENDPOINT, params={"query": query},
                    headers={"X-API-Key": api_key, "Accept": "application/json"}, timeout=20, logger=logger,
                )
                if failure is not None:
                    return failure
                found = rows(data, limit)
                logger.info("TinyFish Search '%s': %d results", query, len(found))
                return search_ok(found)

            return run_search("TinyFish Search", logger, body)

        def get_setup_schema(self) -> dict[str, Any]:
            return setup_schema(
                "TinyFish Search", "free", "Free API key: 12,000 searches a day, search only.",
                KEY_ENV, "TinyFish API key", "https://agent.tinyfish.ai/api-keys",
            )

    return TinyFishWebSearchProvider()


def register(ctx) -> None:
    ctx.register_web_search_provider(make_provider())
