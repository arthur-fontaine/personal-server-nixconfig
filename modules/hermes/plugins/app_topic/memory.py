"""Hermes' memory as the app browses it: unii's volumes, read-only
(docs/app-protocol.md §4, `memory.volumes` and `memory.lines`).

A volume is a log of messages and a binary tree of one-line summaries; node
(l, i) covers the 2^l messages from i·2^l and the app names it by its first
message and count (`unii/volume.py`, `node_name`). The first level is the view
Hermes sees now; a line opens on its two children, a one-message line on the
message.

Reading never writes: `runtime.volume()` would open a closed volume with a
Compactor, which builds its missing summaries (model calls, tree writes). A
volume the runtime already has open is read under its lock; any other is
opened here alone, without a compactor, and kept until its files change.
"""

from __future__ import annotations

import os
import sys
import threading
from importlib import import_module

from . import protocol

MAIN = "main"
# A summary line is at most unii's line_bytes (512 by default): this only
# guards against a node written by hand.
LINE_TEXT_MAX = 1200
# The reply's own envelope is measured with a request id this large.
_RE = 2**31


class Refused(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def runtime():
    state = sys.__dict__.get("_hermes_unii_state") or {}
    found = state.get("runtime")
    if found is None:
        raise Refused("unavailable", "unii's memory is not loaded")
    return found


def _unii(rt, name: str):
    """A module of the unii package the runtime came from (Hermes may import it twice)."""
    package = type(rt).__module__.rpartition(".")[0]
    return import_module(f"{package}.{name}" if package else name)


# ── which volumes ────────────────────────────────────────────────────────

def _subchats(rt, owner: int, app_thread) -> list[tuple[int, object, str, object]]:
    """(topic, record, volume, policy) of each sub-chat of the owner's DM with a volume of its own."""
    Chat = _unii(rt, "policy").Chat
    with rt.policies._lock:
        records = dict(rt.policies._chats)
    out = []
    for key, record in records.items():
        parts = key.split(":")
        if len(parts) != 4 or parts[0] != "telegram" or parts[1] != "dm" or parts[2] != str(owner):
            continue
        try:
            topic = int(parts[3])
        except ValueError:
            continue
        if topic == app_thread:
            continue
        policy, own, _ = rt.chat_volumes(Chat.from_key(key))
        if own == MAIN or not _exists(rt, own):
            continue
        out.append((topic, record, own, policy))
    return sorted(out, key=lambda s: s[0])


def _exists(rt, name: str) -> bool:
    return name in getattr(rt, "_volumes", {}) or os.path.isdir(os.path.join(rt.volumes_dir, name))


def _resolve(rt, owner: int | None, app_thread, chat) -> tuple[str, object]:
    try:
        chat = int(chat or 0)
    except (TypeError, ValueError):
        raise Refused("bad_request", "chat is a topic id, 0 for the main chat") from None
    if chat == 0:
        return MAIN, None
    if owner is None:
        raise Refused("not_found", f"no memory for chat {chat}")
    for topic, _, name, policy in _subchats(rt, owner, app_thread):
        if topic == chat:
            return name, policy
    raise Refused("not_found", f"no memory for chat {chat}")


def _count_lines(path: str) -> int:
    try:
        with open(path, "rb") as f:
            return sum(1 for line in f if line.strip())
    except FileNotFoundError:
        return 0


def volumes(owner: int | None, app_thread) -> dict:
    rt = runtime()

    def entry(chat, name, title, policy) -> dict:
        locked = bool(rt.is_locked(name, policy))
        opened = getattr(rt, "_volumes", {}).get(name)
        if locked:
            count = None
        elif opened is not None:
            count = opened.count
        else:
            count = _count_lines(os.path.join(rt.volumes_dir, name, "messages.jsonl"))
        return {"chat": chat, "name": title, "volume": name, "messages": count,
                "locked": locked, "private": bool(rt.encrypted(name, policy))}

    out = [entry(0, MAIN, "Main chat", None)]
    if owner is not None:
        for topic, record, name, policy in _subchats(rt, owner, app_thread):
            out.append(entry(topic, name, getattr(record, "name", "") or None, policy))
    return {"volumes": out}


# ── reading one ──────────────────────────────────────────────────────────

_opened: dict[str, tuple[tuple, object]] = {}
_opened_lock = threading.Lock()


def _signature(directory: str) -> tuple:
    sig = []
    for name in ("messages.jsonl", "tree.jsonl", "view.json"):
        try:
            st = os.stat(os.path.join(directory, name))
            sig.append((st.st_size, st.st_mtime_ns))
        except FileNotFoundError:
            sig.append(None)
    return tuple(sig)


def _volume(rt, name: str, policy):
    if rt.is_locked(name, policy):
        raise Refused("locked", "this memory is locked")
    live = getattr(rt, "_volumes", {}).get(name)
    if live is not None:
        return live
    Volume = _unii(rt, "volume").Volume
    directory = os.path.join(rt.volumes_dir, name)
    with _opened_lock:
        sig = _signature(directory)
        cached = _opened.get(name)
        if cached and cached[0] == sig:
            return cached[1]
        encrypted = bool(rt.encrypted(name, policy))
        volume = Volume(rt.volumes_dir, name, encrypted=encrypted, key=rt.keys.get(name))
        _opened[name] = (sig, volume)
        return volume


def _line(volume, level: int, index: int) -> dict:
    text = volume.nodes.get((level, index))
    return {"first": index << level, "n": 1 << level,
            "text": protocol.cut(text.strip(), LINE_TEXT_MAX) if text is not None else None,
            "built": text is not None}


def _fits(data: dict) -> bool:
    return protocol.fits(protocol.message("reply", re=_RE, ok=True, data=data))


def lines(owner: int | None, app_thread, request: dict) -> dict:
    rt = runtime()
    name, policy = _resolve(rt, owner, app_thread, request.get("chat"))
    volume = _volume(rt, name, policy)
    first, n = request.get("first"), request.get("n")
    with volume._lock:
        if first is None and n is None:
            return _view_page(volume, request.get("after"))
        try:
            first, n = int(first), int(n)
        except (TypeError, ValueError):
            raise Refused("bad_request", "first and n are integers") from None
        if n < 1 or n & (n - 1) or first < 0 or first % n:
            raise Refused("bad_request", f"{first}+{n} is not a line (n a power of 2, first a multiple of n)")
        if first + n > volume.count:
            raise Refused("not_found", f"{first}+{n} goes past the last message ({volume.count - 1})")
        if n == 1:
            return _message(volume.messages[first])
        level = n.bit_length() - 1
        index = first // n
        return {"lines": [_line(volume, level - 1, 2 * index + k) for k in (0, 1)]}


def _view_page(volume, after) -> dict:
    try:
        after = int(after or 0)
    except (TypeError, ValueError):
        raise Refused("bad_request", "after is a message number") from None
    view = [(l, i) for l, i in volume.view if (i << l) >= after]
    data: dict = {"lines": []}
    for k, (level, index) in enumerate(view):
        data["lines"].append(_line(volume, level, index))
        if not _fits({**data, "truncated": True, "next": 2**31}):
            data["lines"].pop()
            data["truncated"], data["next"] = True, index << level
            if not data["lines"]:
                # One line alone does not fit (cannot happen with unii's line size): skip it.
                data["next"] = (index + 1) << level
            break
    return data


def _message(record: dict) -> dict:
    message = {"i": record["i"], "kind": record.get("kind"), "date": record.get("date"),
               "text": record.get("text") or ""}
    if _fits({"message": message}):
        return {"message": message}
    text = message["text"]
    low, high = 0, len(text)
    while low < high:
        mid = (low + high + 1) // 2
        if _fits({"message": {**message, "text": protocol.cut(text, mid), "cut": True}}):
            low = mid
        else:
            high = mid - 1
    return {"message": {**message, "text": protocol.cut(text, low), "cut": True}}
