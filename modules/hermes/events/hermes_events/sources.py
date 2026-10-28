"""Where events come from.

- WhatsApp: `wacli sync --follow --webhook` posts each stored message here,
  signed `X-Wacli-Signature: sha256=<hmac>`; payloads in
  https://github.com/openclaw/wacli/blob/main/docs/sync.md#webhook-payloads.
- iMessage and SMS: `imsg watch --json` streams one message per line (fields
  from imsg's Sources/imsg/OutputModels.swift, MessagePayload).
- HomeKit: HomeClaw posts its triggered events to <url>/hooks/homeclaw as
  {"text": "[Front Door] [Home] HomeKit: ...", "mode": "now" | "next-heartbeat"}
  with a Bearer token (its openclaw/hooks/homeclaw-transform.js).
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import time

from aiohttp import web

from .core import Chat, Message, Pipeline, parse_time

log = logging.getLogger("hermes_events")


def whatsapp_message(payload: dict) -> tuple[Chat, Message, bool] | None:
    """(chat, message, from_me), or None for what is not a message."""
    if payload.get("EventType", "message") != "message":
        return None
    jid = payload.get("Chat") or ""
    if not jid or not payload.get("ID"):
        return None
    is_group = jid.endswith("@g.us")
    text = payload.get("Text") or ""
    media = payload.get("Media") or None
    if media:
        caption = media.get("Caption") or ""
        text = f"[{media.get('Type') or 'file'}] {caption}".strip() if not text else text
    if not text:
        return None
    name = payload.get("ChatName") or jid.split("@")[0]
    sender = "me" if payload.get("FromMe") else (name if not is_group else payload.get("SenderJID", "").split("@")[0])
    chat = Chat("whatsapp", jid, name, is_group, reply_hint=f'`wacli send text --to "{jid}" --message "…"`')
    message = Message(payload["ID"], parse_time(payload["Timestamp"]), sender, text)
    return chat, message, bool(payload.get("FromMe"))


def whatsapp_app(pipeline: Pipeline, secret: str) -> web.Application:
    async def receive(request: web.Request) -> web.Response:
        body = await request.read()
        expected = "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(request.headers.get("X-Wacli-Signature", ""), expected):
            return web.Response(status=401)
        try:
            parsed = whatsapp_message(json.loads(body))
        except (ValueError, KeyError, TypeError) as err:
            log.warning("unreadable WhatsApp payload: %s", err)
            return web.Response(status=400)
        if parsed:
            chat, message, from_me = parsed
            if from_me:
                pipeline.own_message(chat)
            else:
                pipeline.message(chat, message)
        return web.Response(status=204)

    async def homekit(request: web.Request) -> web.Response:
        if not hmac.compare_digest(request.headers.get("Authorization", ""), f"Bearer {secret}"):
            return web.Response(status=401)
        try:
            payload = await request.json()
        except ValueError:
            return web.Response(status=400)
        text = str(payload.get("text", "")).strip()
        if text and "Webhook test event" not in text:
            # One accessory's change, deduped within the minute it happened.
            accessory = text.split("]")[0].lstrip("[") or "home"
            digest = hashlib.sha256(f"{text}{int(time.time() // 60)}".encode()).hexdigest()[:16]
            pipeline.notice("homekit", accessory, f"HomeKit: {accessory}", text, id=digest)
        return web.json_response({"ok": True})

    app = web.Application(client_max_size=1 << 20)
    app.router.add_post("/whatsapp", receive)
    app.router.add_post("/hooks/homeclaw", homekit)
    return app


def imessage_message(payload: dict) -> tuple[Chat, Message, bool] | None:
    if payload.get("is_reaction") or payload.get("unsent_at") or payload.get("edited_at"):
        return None
    text = payload.get("text") or ""
    if not text and payload.get("attachments"):
        text = "[attachment]"
    if not text or payload.get("chat_id") is None or not payload.get("guid"):
        return None
    sender = payload.get("sender") or ""
    name = payload.get("sender_name") or sender
    chat_id = str(payload["chat_id"])
    chat = Chat("imessage", chat_id, name, reply_hint=f'`imsg send --chat-id {chat_id} --text "…"`')
    from_me = bool(payload.get("is_from_me"))
    message = Message(payload["guid"], parse_time(payload["created_at"]), "me" if from_me else name, text)
    return chat, message, from_me


async def imessage_watch(pipeline: Pipeline, command: list[str]) -> None:
    """Runs `imsg watch --json` for good, restarting it when it stops."""
    delay = 5
    while True:
        try:
            process = await asyncio.create_subprocess_exec(*command, stdout=asyncio.subprocess.PIPE)
            assert process.stdout
            async for line in process.stdout:
                try:
                    parsed = imessage_message(json.loads(line))
                except (ValueError, KeyError, TypeError):
                    continue
                if parsed:
                    chat, message, from_me = parsed
                    pipeline.own_message(chat) if from_me else pipeline.message(chat, message)
            await process.wait()
            log.warning("imsg watch exited (%s), restarting", process.returncode)
        except OSError as err:
            log.warning("imsg watch failed to start: %s", err)
        await asyncio.sleep(delay)
        delay = min(delay * 2, 300)
