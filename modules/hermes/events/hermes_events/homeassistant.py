"""Home Assistant's state changes, over its WebSocket API
(https://developers.home-assistant.io/docs/api/websocket): authenticate with
the long-lived token, subscribe to state_changed, keep the watched domains
and entities, and only real changes of state (not attribute updates)."""

from __future__ import annotations

import asyncio
import json
import logging
import time

import aiohttp

from .core import Pipeline

log = logging.getLogger("hermes_events")


def change(event: dict, domains: set[str], entities: set[str]) -> tuple[str, str, str] | None:
    """(entity_id, summary, details) for a watched change of state, else None."""
    data = event.get("data", {})
    entity = data.get("entity_id", "")
    old, new = data.get("old_state") or {}, data.get("new_state") or {}
    if not entity or not new:
        return None
    if entity not in entities and entity.split(".")[0] not in domains:
        return None
    before, after = old.get("state"), new.get("state")
    if before == after or after in ("unavailable", "unknown") and before in ("unavailable", "unknown", None):
        return None
    name = new.get("attributes", {}).get("friendly_name") or entity
    return entity, f"Home Assistant: {name} is now {after}", f"{name} ({entity}): {before} → {after}"


def websocket_url(url: str) -> str:
    return url.rstrip("/").replace("https://", "wss://", 1).replace("http://", "ws://", 1) + "/api/websocket"


async def homeassistant_watch(pipeline: Pipeline, url: str, token: str, domains: list[str], entities: list[str],
                              cooldown: float = 30) -> None:
    domains_set, entities_set = set(domains), set(entities)
    last: dict[str, float] = {}
    delay = 5
    while True:
        try:
            async with aiohttp.ClientSession() as session:
                async with session.ws_connect(websocket_url(url), heartbeat=30) as ws:
                    await ws.receive_json()  # auth_required
                    await ws.send_json({"type": "auth", "access_token": token})
                    answer = await ws.receive_json()
                    if answer.get("type") != "auth_ok":
                        log.warning("Home Assistant refused the token: %s", answer.get("message"))
                        await asyncio.sleep(3600)
                        continue
                    await ws.send_json({"id": 1, "type": "subscribe_events", "event_type": "state_changed"})
                    log.info("watching Home Assistant's state changes")
                    delay = 5
                    async for frame in ws:
                        if frame.type != aiohttp.WSMsgType.TEXT:
                            continue
                        message = json.loads(frame.data)
                        if message.get("type") != "event":
                            continue
                        found = change(message.get("event", {}), domains_set, entities_set)
                        if not found:
                            continue
                        entity, summary, details = found
                        # A flapping sensor is one event per cooldown.
                        now = time.time()
                        if now - last.get(entity, 0) < cooldown:
                            continue
                        last[entity] = now
                        pipeline.notice("homeassistant", entity, summary, details, id=f"{entity}@{int(now)}")
        except Exception as err:
            log.warning("Home Assistant at %s unavailable: %s", url, err)
        await asyncio.sleep(delay)
        delay = min(delay * 2, 300)
