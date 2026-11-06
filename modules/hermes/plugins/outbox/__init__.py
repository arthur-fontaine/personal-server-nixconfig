"""outbox: a reply never claims to attach a file the gateway will not send.

The gateway drops a ``MEDIA:<path>`` it refuses to deliver without telling
anyone (gateway/platforms/base.py, ``validate_media_delivery_path``): the user
gets the reply with the tag stripped and no file, and the model goes on
believing it sent one. It refused every screenshot of the browser here, which
the harness writes under ``~/.config``, a denied credential directory: the user
asked four times for an image that never left the Mac, and was told each time
that it was attached.

``transform_llm_output`` fires on the finished reply, before delivery and
before the turn is stored, so rewriting the tag there reaches the user and the
next turn's history alike: both then know the file was not sent.

Copying the file into a deliverable directory instead would defeat the list it
was refused by (that is where credentials live), so the plugin reports, and
never moves anything.
"""

from __future__ import annotations

import logging
import os
import re
from pathlib import Path
from typing import Callable, Optional

logger = logging.getLogger(__name__)

# What the gateway refuses, when it is not imported here to ask (see
# _validator): gateway/platforms/base.py, _MEDIA_DELIVERY_DENIED_* and
# _ROOT_CREDENTIAL_PATHS, at the pinned revision.
_DENIED_PREFIXES = (
    "/etc", "/proc", "/sys", "/dev", "/root", "/boot", "/var/log", "/var/lib", "/var/run",
)
_DENIED_HOME = (
    ".ssh", ".aws", ".gnupg", ".kube", ".docker", ".config", ".azure", ".gcloud",
    "Library/Keychains",
)
_DENIED_HOME_FILES = (
    ".env", "auth.json", "auth.lock", "credentials", "config.yaml", ".anthropic_oauth.json",
    "google_token.json", "google_oauth_pending.json", "auth/google_oauth.json",
    "webhook_subscriptions.json", "cache/bws_cache.json", "cache/bws_cache.enc.json",
    "pairing", "mcp-tokens", "webapp", "sessions", "browser-profile",
    "state.db", "state.db-wal", "state.db-shm", "state.db-journal",
    "kanban.db", "kanban.db-wal", "kanban.db-shm", "kanban.db-journal",
)

# A MEDIA tag takes no space in its path (the gateway's own scan, same rule).
MEDIA_RE = re.compile(r"MEDIA:[ \t]*(?P<path>[^\s)\]>\"'`]+)")
MD_IMAGE_RE = re.compile(r"!\[(?P<alt>[^\]]*)\]\(\s*(?P<path>[^)\s]+)\s*\)")
# Sentence punctuation clings to a path that ends a clause.
_TRAILING = ".,;:!?"

WHERE_TO_PUT = "copy it under ~/.hermes/cache/documents first"


def _validator() -> Optional[Callable[[str], Optional[str]]]:
    """The gateway's own verdict, once it can be imported in this process."""
    try:
        from gateway.platforms.base import validate_media_delivery_path
    except Exception:  # the CLI: no gateway loaded, or it moved upstream
        return None
    return validate_media_delivery_path


def _under(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def _refused_locally(path: Path) -> bool:
    """The denied-location half of the gateway's policy, for when it cannot be asked."""
    home = Path(os.path.expanduser("~")).resolve()
    for prefix in _DENIED_PREFIXES:
        root = Path(prefix).resolve()
        if root != home and _under(path, root):
            return True
    if any(_under(path, (home / sub).resolve()) for sub in _DENIED_HOME):
        return True
    return any(_under(path, (home / ".hermes" / sub).resolve()) for sub in _DENIED_HOME_FILES)


def deliverable(raw: str, validate: Optional[Callable[[str], Optional[str]]] = None) -> bool:
    """Whether the gateway would attach ``raw`` to the reply."""
    path = raw[len("MEDIA:"):] if raw.upper().startswith("MEDIA:") else raw
    path = os.path.expanduser(path.strip().rstrip(_TRAILING))
    if not path.startswith("/"):
        return False
    check = validate if validate is not None else _validator()
    if check is not None:
        try:
            return bool(check(path))
        except Exception:
            logger.debug("outbox: the gateway's check failed on %s", path, exc_info=True)
    resolved = Path(path)
    try:
        resolved = resolved.resolve(strict=True)
    except (OSError, RuntimeError, ValueError):
        return False
    return resolved.is_file() and not _refused_locally(resolved)


def _note(kind: str, raw: str) -> str:
    path = os.path.expanduser(raw.strip().rstrip(_TRAILING))
    return f"[{kind} not sent: {path} — the gateway refuses files there; {WHERE_TO_PUT}]"


def rescue(text: str, validate: Optional[Callable[[str], Optional[str]]] = None) -> Optional[str]:
    """``text`` with each undeliverable attachment replaced by a sentence saying so.

    None when the reply is already honest about its attachments, so the hook
    leaves every other reply untouched.
    """
    if not text or ("MEDIA:" not in text and "](" not in text):
        return None
    changed = False

    def swap(kind: str):
        def replace(match: re.Match) -> str:
            nonlocal changed
            if deliverable(match.group("path"), validate):
                return match.group(0)
            changed = True
            logger.info("outbox: %s not delivered: %s", kind, match.group("path"))
            return _note(kind, match.group("path"))
        return replace

    text = MD_IMAGE_RE.sub(swap("image"), text)
    text = MEDIA_RE.sub(swap("attachment"), text)
    return text if changed else None


def on_output(response_text: str = "", **kwargs) -> Optional[str]:
    """The ``transform_llm_output`` hook."""
    try:
        return rescue(response_text)
    except Exception:  # never break a reply over this
        logger.warning("outbox: could not check the reply's attachments", exc_info=True)
        return None


def register(ctx) -> None:
    ctx.register_hook("transform_llm_output", on_output)
