"""Posts an event to Hermes' webhook route, signed the generic V2 way: hex
HMAC-SHA256 of "<timestamp>.<body>" (gateway/platforms/webhook.py in Hermes)."""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import time

import aiohttp

log = logging.getLogger("hermes_events")


def sign(secret: str, body: bytes, timestamp: str) -> str:
    return hmac.new(secret.encode(), timestamp.encode() + b"." + body, hashlib.sha256).hexdigest()


class HermesSink:
    def __init__(self, url: str, secret: str, owner: str, clock=time.time):
        self.url, self.secret, self.owner, self.clock = url, secret, owner, clock

    def request(self, event: dict) -> tuple[bytes, dict]:
        # The owner's id is the main chat's (their DM with the bot): deliver_extra.chat_id.
        body = json.dumps({**event, "owner": self.owner}, ensure_ascii=False).encode()
        timestamp = str(int(self.clock()))
        return body, {
            "Content-Type": "application/json",
            "X-Webhook-Timestamp": timestamp,
            "X-Webhook-Signature-V2": sign(self.secret, body, timestamp),
        }

    async def post(self, event: dict) -> bool:
        body, headers = self.request(event)
        try:
            timeout = aiohttp.ClientTimeout(total=30)
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.post(self.url, data=body, headers=headers) as response:
                    if response.status >= 300:
                        log.warning("hermes refused %s: %s %s", event["key"], response.status, await response.text())
                        return False
            log.info("%s: sent to Hermes (%s)", event["key"], event.get("urgency"))
            return True
        except Exception as err:
            log.warning("hermes unreachable for %s: %s", event["key"], err)
            return False
