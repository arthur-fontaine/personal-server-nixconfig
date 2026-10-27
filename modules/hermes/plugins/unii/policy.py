"""Which chat a session belongs to, and what that chat may do.

The main chat is the owner's direct conversation with the bot (the root of the
Telegram DM, the CLI over SSH). Every topic of that DM, and every group, group
topic or channel with the bot, is a sub-chat, whose policy comes from a preset
(config.json, written by Nix) plus the changes made with `/sub set`, kept in
chats.json.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import threading
import time
from dataclasses import asdict, dataclass, field, fields, replace

MAIN = "main"

# Sessions that are not a conversation: they read the main memory, never write it.
PASSIVE_PLATFORMS = {"subagent", "cron", "batch", "kanban", "webhook"}


# Telegram's General topic arrives with no thread id or with "1": both are the root.
ROOT_THREADS = {"", "1"}


@dataclass(frozen=True)
class Chat:
    platform: str
    chat_type: str
    chat_id: str
    thread: str = ""

    def __post_init__(self):
        if self.thread in ROOT_THREADS:
            object.__setattr__(self, "thread", "")

    @property
    def key(self) -> str:
        base = f"{self.platform}:{self.chat_type}:{self.chat_id}"
        return f"{base}:{self.thread}" if self.thread else base

    @property
    def is_main(self) -> bool:
        return self.platform == "cli" or (self.chat_type == "dm" and not self.thread)

    @classmethod
    def from_key(cls, key: str) -> "Chat":
        platform, chat_type, rest = key.split(":", 2)
        chat_id, _, thread = rest.partition(":")
        return cls(platform, chat_type, chat_id, thread)

    @classmethod
    def from_session_key(cls, session_key: str | None, platform: str | None) -> "Chat | None":
        """Parse ``agent:<ns>:<platform>:<chat_type>:<chat_id>[:<thread_id>]`` (gateway/session.py,
        build_session_key). Group keys carry no participant: the agent sets
        group_sessions_per_user to false, so a sixth part is always a thread."""
        if session_key:
            parts = session_key.split(":")
            if len(parts) >= 5 and parts[0] == "agent":
                return cls(parts[2], parts[3], parts[4], parts[5] if len(parts) > 5 else "")
            if len(parts) == 4 and parts[0] == "agent":
                return cls(parts[2], parts[3], "")
        if platform == "cli":
            return cls("cli", "dm", "")
        return None

    @classmethod
    def from_source(cls, source) -> "Chat":
        platform = getattr(source.platform, "value", source.platform)
        return cls(str(platform), source.chat_type or "dm", source.chat_id or "", str(source.thread_id or ""))


@dataclass(frozen=True)
class Policy:
    memoryRead: bool = False
    memoryWrite: bool = False
    volume: str | None = None
    tools: tuple[str, ...] | None = None
    ttl: str | None = None
    encrypted: bool = False
    model: str | None = None

    @classmethod
    def from_dict(cls, data: dict) -> "Policy":
        known = {f.name for f in fields(cls)}
        values = {k: v for k, v in data.items() if k in known}
        if values.get("tools") is not None:
            values["tools"] = tuple(values["tools"])
        return cls(**values)

    def to_dict(self) -> dict:
        data = asdict(self)
        if data["tools"] is not None:
            data["tools"] = list(data["tools"])
        return data


MAIN_POLICY = Policy(memoryRead=True, memoryWrite=True, volume=MAIN)

_DURATION = re.compile(r"^(\d+)\s*([smhdw])$")
_UNITS = {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}


def ttl_seconds(ttl: str | None) -> float | None:
    """Seconds for a duration ttl; None for permanent or "session"."""
    if not ttl or ttl == "session":
        return None
    match = _DURATION.match(ttl.strip())
    if not match:
        raise ValueError(f"bad ttl {ttl!r}: use 30m, 6h, 7d, session or none")
    return int(match.group(1)) * _UNITS[match.group(2)]


def parse_setting(key: str, value: str):
    """A `/sub set <key> <value>` value, typed."""
    value = value.strip()
    if key in ("memoryRead", "memoryWrite", "encrypted"):
        if value.lower() in ("on", "true", "yes", "1"):
            return True
        if value.lower() in ("off", "false", "no", "0"):
            return False
        raise ValueError(f"{key} is on or off")
    if key in ("volume", "model", "ttl"):
        if value.lower() in ("none", "null", ""):
            return None
        if key == "ttl":
            ttl_seconds(value)
        return value
    if key == "tools":
        if value.lower() in ("all", "none", "null"):
            return None if value.lower() != "none" else ()
        return tuple(t.strip() for t in value.split(",") if t.strip())
    raise ValueError(f"unknown setting {key!r}")


@dataclass
class ChatRecord:
    preset: str
    overrides: dict = field(default_factory=dict)
    last_active: float = 0.0
    session_ids: list = field(default_factory=list)


class Policies:
    """Presets and the state of every sub-chat. Thread-safe; chats.json is rewritten atomically."""

    def __init__(self, config: dict, state_dir: str):
        self.presets = {name: Policy.from_dict(p) for name, p in config.get("presets", {}).items()}
        self.default_preset = config.get("default_preset", next(iter(self.presets), ""))
        self.volumes = config.get("volumes", {})
        self._path = os.path.join(state_dir, "chats.json")
        self._lock = threading.RLock()
        try:
            with open(self._path) as f:
                raw = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            raw = {}
        self._chats = {key: ChatRecord(**value) for key, value in raw.items()}

    def _save(self) -> None:
        tmp = self._path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({k: asdict(v) for k, v in self._chats.items()}, f, indent=1)
        os.replace(tmp, self._path)

    def _record(self, chat: Chat) -> ChatRecord:
        record = self._chats.get(chat.key)
        if record is None:
            record = ChatRecord(preset=self.default_preset)
            self._chats[chat.key] = record
        return record

    def policy(self, chat: Chat) -> Policy:
        if chat.is_main:
            return MAIN_POLICY
        with self._lock:
            record = self._record(chat)
            base = self.presets.get(record.preset, Policy())
            overrides = dict(record.overrides)
            if overrides.get("tools") is not None:
                overrides["tools"] = tuple(overrides["tools"])
            policy = replace(base, **overrides) if overrides else base
        named = self.volumes.get(policy.volume or "", {})
        if named.get("encrypted") and not policy.encrypted:
            policy = replace(policy, encrypted=True)
        return policy

    def preset_name(self, chat: Chat) -> str:
        with self._lock:
            return self._record(chat).preset

    def set_preset(self, chat: Chat, name: str) -> Policy:
        if name not in self.presets:
            raise ValueError(f"no preset {name!r} (presets: {', '.join(sorted(self.presets))})")
        with self._lock:
            record = self._record(chat)
            record.preset, record.overrides = name, {}
            self._save()
        return self.policy(chat)

    def set(self, chat: Chat, key: str, value) -> Policy:
        with self._lock:
            record = self._record(chat)
            record.overrides[key] = list(value) if isinstance(value, tuple) else value
            self._save()
        return self.policy(chat)

    def touch(self, chat: Chat, session_id: str | None = None) -> None:
        if chat.is_main:
            return
        with self._lock:
            record = self._record(chat)
            record.last_active = time.time()
            if session_id and session_id not in record.session_ids:
                record.session_ids.append(session_id)
            self._save()

    def forget_sessions(self, chat: Chat) -> list[str]:
        with self._lock:
            record = self._record(chat)
            ids, record.session_ids = record.session_ids, []
            self._save()
            return ids

    def expired(self, now: float) -> list[Chat]:
        """Sub-chats whose duration ttl has run out since their last message."""
        out = []
        with self._lock:
            for key, record in self._chats.items():
                chat = Chat.from_key(key)
                try:
                    seconds = ttl_seconds(self.policy(chat).ttl)
                except ValueError:
                    continue
                if seconds and record.last_active and now - record.last_active > seconds and record.session_ids:
                    out.append(chat)
        return out


def own_volume(chat: Chat) -> str:
    """The private volume of a sub-chat that names none."""
    return "chat-" + hashlib.sha256(chat.key.encode()).hexdigest()[:16]


def write_volume(chat: Chat, policy: Policy) -> str:
    if chat.is_main:
        return MAIN
    return policy.volume or own_volume(chat)


def readable_volumes(chat: Chat, policy: Policy) -> list[str]:
    """The volumes shown in the chat's view, its own first."""
    own = write_volume(chat, policy)
    volumes = [own]
    if policy.memoryRead and own != MAIN:
        volumes.append(MAIN)
    return volumes
