"""APNs pushes to the app, when the team is a paid one (docs/app-protocol.md §4).

A free personal team cannot use APNs at all, so tokens are only stored then.
With a key (server.hermes.app.apns: key id, team id, bundle id; the .p8 in
the secrets file as APNS_KEY), `notify` messages go out as alerts and the
agent's state as Live Activity updates.
https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
from pathlib import Path

logger = logging.getLogger("app_topic.push")

JWT_TTL = 50 * 60  # Apple: refresh between 20 and 60 minutes


class Push:
    def __init__(self, config: dict, path: Path):
        self.config = config or {}
        self.path = Path(path)
        self.lock = threading.Lock()
        try:
            self.tokens = json.loads(self.path.read_text())
        except (OSError, ValueError):
            self.tokens = {}
        self._jwt: tuple[str, float] | None = None

    @property
    def enabled(self) -> bool:
        return bool(self.config.get("enable") and self.config.get("key_id") and self.config.get("team_id")
                    and os.environ.get(self.config.get("key_env") or "APNS_KEY"))

    def _save(self) -> None:
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.tokens, indent=1))
        os.replace(tmp, self.path)

    async def register(self, request: dict, message_id=None) -> dict:
        token = str(request.get("token_hex") or "").strip().lower()
        kind = request.get("kind")
        if not token or not all(c in "0123456789abcdef" for c in token) or kind not in ("alert", "liveactivity",
                                                                                        "pushtostart"):
            from .app import RequestError

            raise RequestError("bad_request", "token_hex and kind (alert|liveactivity|pushtostart) are required")
        with self.lock:
            self.tokens[token] = {"kind": kind, "sandbox": bool(request.get("sandbox")),
                                  "bundle_id": request.get("bundle_id") or self.config.get("bundle_id"),
                                  "activity_id": request.get("activity_id"), "at": time.time()}
            self._save()
        return {"stored": True, "apns": self.enabled}

    async def unregister(self, request: dict, message_id=None) -> dict:
        with self.lock:
            self.tokens.pop(str(request.get("token_hex") or "").lower(), None)
            self._save()
        return {}

    def jwt(self) -> str:
        import jwt

        if self._jwt and time.time() - self._jwt[1] < JWT_TTL:
            return self._jwt[0]
        key = os.environ[self.config.get("key_env") or "APNS_KEY"].replace("\\n", "\n")
        token = jwt.encode({"iss": self.config["team_id"], "iat": int(time.time())}, key, algorithm="ES256",
                           headers={"kid": self.config["key_id"]})
        self._jwt = (token, time.time())
        return token

    async def send(self, kinds: tuple[str, ...], payload: dict, push_type: str, topic_suffix: str = "",
                   priority: int = 10) -> None:
        if not self.enabled:
            return
        import httpx

        with self.lock:
            targets = [(t, v) for t, v in self.tokens.items() if v["kind"] in kinds]
        if not targets:
            return
        async with httpx.AsyncClient(http2=True, timeout=15) as client:
            for token, info in targets:
                host = "api.sandbox.push.apple.com" if info.get("sandbox") else "api.push.apple.com"
                headers = {"authorization": f"bearer {self.jwt()}", "apns-push-type": push_type,
                           "apns-topic": f"{info.get('bundle_id')}{topic_suffix}", "apns-priority": str(priority)}
                try:
                    response = await client.post(f"https://{host}/3/device/{token}", headers=headers, json=payload)
                except Exception as error:
                    logger.info("app_topic: APNs unreachable: %s", error)
                    return
                if response.status_code == 410 or (response.status_code == 400 and "BadDeviceToken" in response.text):
                    with self.lock:
                        self.tokens.pop(token, None)
                        self._save()
                elif response.status_code >= 400:
                    logger.info("app_topic: APNs %s: %s", response.status_code, response.text[:200])

    async def notify(self, obj: dict) -> None:
        level = "time-sensitive" if obj.get("interruption") == "time-sensitive" else "active"
        payload = {"aps": {"alert": {"title": obj.get("title"), "body": obj.get("spoken") or obj.get("body")},
                           "sound": "default", "interruption-level": level,
                           "thread-id": f"chat-{obj.get('chat', 0)}"},
                   "hermes": {k: obj.get(k) for k in ("chat", "message_id", "kind", "body")}}
        await self.send(("alert",), payload, "alert")

    async def activity(self, agent: dict, question: dict | None) -> None:
        state = {"status": agent.get("status"), "task": agent.get("task"), "chat": agent.get("chat"),
                 "question": ({k: question.get(k) for k in ("id", "kind", "text", "summary", "options", "chat",
                                                             "message_id")} if question else None)}
        payload = {"aps": {"timestamp": int(time.time()), "event": "update", "content-state": state}}
        if agent.get("status") == "idle":
            payload["aps"]["event"] = "end"
            payload["aps"]["dismissal-date"] = int(time.time()) + 60
        await self.send(("liveactivity",), payload, "liveactivity", ".push-type.liveactivity", priority=5)
