"""The few Bot API calls the plugin makes itself: the DM topics that are sub-chats.

Users cannot create topics (BotFather: "Disallow users to create new threads"),
so a message at the DM's root stays there, in the main chat, and only the bot
opens topics: https://core.telegram.org/bots/api#createforumtopic.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request


class BotAPIError(RuntimeError):
    pass


class BotAPI:
    def __init__(self, token: str | None = None):
        self.token = token if token is not None else os.environ.get("TELEGRAM_BOT_TOKEN", "")

    def call(self, method: str, **params) -> dict:
        if not self.token:
            raise BotAPIError("TELEGRAM_BOT_TOKEN is not set")
        data = urllib.parse.urlencode({k: v for k, v in params.items() if v is not None}).encode()
        request = urllib.request.Request(f"https://api.telegram.org/bot{self.token}/{method}", data=data)
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                body = json.load(response)
        except urllib.error.HTTPError as err:
            try:
                body = json.load(err)
            except Exception:
                raise BotAPIError(f"{method}: HTTP {err.code}") from None
        except OSError as err:
            raise BotAPIError(f"{method}: {err}") from None
        if not body.get("ok"):
            raise BotAPIError(body.get("description") or f"{method} failed")
        return body["result"]

    def create_topic(self, chat_id: str, name: str) -> str:
        return str(self.call("createForumTopic", chat_id=chat_id, name=name[:128])["message_thread_id"])

    def send(self, chat_id: str, thread: str, text: str) -> None:
        self.call("sendMessage", chat_id=chat_id, message_thread_id=thread or None, text=text)

    def delete_topic(self, chat_id: str, thread: str) -> None:
        self.call("deleteForumTopic", chat_id=chat_id, message_thread_id=thread)
