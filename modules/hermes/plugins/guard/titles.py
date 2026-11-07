"""A shell command named in plain words, above it on its approval card.

Ported from Arthur's Pi extension bash-titles (titles.ts, index.ts): the same
``wants_title`` heuristic (only commands too long or tangled to read at a
glance), the same prompt, the same clean-up of the answer (``title_of``), and
titles kept on disk by command so none is asked for twice. The Pi extension
asks Claude Haiku through the Claude subscription; Hermes asks its auxiliary
model (task ``approval``, thinking off), the command alone sent, no
conversation. After a failure, no request for a minute; the card never waits
past ``TIMEOUT`` seconds and goes out without a title when there is none.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import threading
import time
from collections import OrderedDict
from pathlib import Path
from typing import Callable, Optional

logger = logging.getLogger(__name__)

MAX_TOKENS = 40
TIMEOUT = 8.0
PAUSE = 60.0


def wants_title(command: str) -> bool:
    """As pi-harness's pi-thinking-summary: a short, simple command is read as is."""
    text = command.strip()
    if not text:
        return False
    steps = len(re.findall(r";|&&|\|\|?", text))
    return len(text) > 80 or "\n" in text or steps > 2


SYSTEM = " ".join([
    "You name shell commands for a person scanning an agent's activity.",
    "Reply with one short phrase of 3 to 8 words saying what the command does, starting with a verb",
    "in the third person (\"Lists the largest session files\", \"Runs the editor's unit tests\").",
    "Name its purpose, not its flags; never say whether it worked. No quotes, no final period.",
])


def request(command: str, max_chars: int = 1500) -> str:
    """Only the command goes out: its head and tail when it is long."""
    text = command.strip()
    if len(text) <= max_chars:
        return text
    return f"{text[:int(max_chars * 0.7)]}\n…\n{text[-int(max_chars * 0.3):]}"


MAX_WORDS = 12
MAX_CHARS = 90


def title_of(reply: str) -> Optional[str]:
    """The answer's first line, cut to a few words."""
    first = (reply or "").strip().split("\n")[0]
    text = re.sub(r"^[\"'`]+|[\"'`.]+$", "", first.strip()).strip()
    if not text:
        return None
    words = text.split()
    if len(words) > MAX_WORDS:
        text = re.sub(r"[,;:]$", "", " ".join(words[:MAX_WORDS])) + "…"
    if len(text) > MAX_CHARS:
        text = text[:MAX_CHARS - 1].rstrip() + "…"
    return text[0].upper() + text[1:]


def key_of(command: str) -> str:
    return hashlib.sha256(command.strip().encode()).hexdigest()[:32]


class TitleCache:
    """Titles by command, oldest dropped past ``max``."""

    def __init__(self, entries: Optional[dict] = None, max_size: int = 3000) -> None:
        self.max = max_size
        self.map: "OrderedDict[str, str]" = OrderedDict(entries or {})

    def get(self, command: str) -> Optional[str]:
        return self.map.get(key_of(command))

    def set(self, command: str, title: str) -> None:
        key = key_of(command)
        self.map.pop(key, None)
        self.map[key] = title
        while len(self.map) > self.max:
            self.map.popitem(last=False)

    def to_json(self) -> dict:
        return dict(self.map)


def _ask_auxiliary(command: str) -> str:
    from agent.auxiliary_client import call_llm

    response = call_llm(
        task="approval", temperature=0, max_tokens=MAX_TOKENS, timeout=TIMEOUT,
        messages=[{"role": "system", "content": SYSTEM}, {"role": "user", "content": request(command)}],
        reasoning_config={"enabled": False},
    )
    return response.choices[0].message.content or ""


class Titles:
    def __init__(self, file: Optional[Path] = None, ask: Callable[[str], str] = _ask_auxiliary,
                 clock: Callable[[], float] = time.monotonic) -> None:
        self.file = file
        self.ask = ask
        self.clock = clock
        self.paused_until = 0.0
        self.lock = threading.Lock()
        entries = {}
        try:
            entries = json.loads(file.read_text()) if file else {}
        except (OSError, ValueError):
            pass
        self.cache = TitleCache(entries if isinstance(entries, dict) else {})

    def _save(self) -> None:
        if not self.file:
            return
        try:
            self.file.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.file.with_name(f"{self.file.name}.{os.getpid()}")
            tmp.write_text(json.dumps(self.cache.to_json()))
            tmp.replace(self.file)
        except OSError:
            pass

    def title(self, command: str) -> str:
        if not wants_title(command):
            return ""
        with self.lock:
            known = self.cache.get(command)
            if known or self.clock() < self.paused_until:
                return known or ""
        try:
            text = title_of(self.ask(command))
        except Exception as error:  # noqa: BLE001 - the card goes out without it
            logger.warning("guard: no title for the command (%s)", error)
            with self.lock:
                self.paused_until = self.clock() + PAUSE
            return ""
        if not text:
            # A reply that isn't a title is dropped, not asked again.
            return ""
        with self.lock:
            self.cache.set(command, text)
            self._save()
        return text


_TITLES: Optional[Titles] = None


def title(command: str) -> str:
    global _TITLES
    if _TITLES is None:
        try:
            from hermes_constants import get_hermes_home

            file = Path(get_hermes_home()) / "guard" / "titles.json"
        except Exception:  # noqa: BLE001 - outside Hermes, no disk cache
            file = None
        _TITLES = Titles(file)
    return _TITLES.title(command)
