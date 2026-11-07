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

Only what the gateway itself would try to deliver is judged: a ``MEDIA:`` tag,
or a markdown image of a local path, outside code and quotes (the gateway
masks those as examples, ``_mask_protected_spans``). A remote image is the
gateway's to fetch and is left alone.

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
# The operator allowlist beats the denylist (gateway.media_delivery_allow_dirs,
# bridged to this variable at gateway start; browser.nix opens the harness'
# screenshots with it).
_ALLOW_DIRS_ENV = "HERMES_MEDIA_ALLOW_DIRS"

# A tag's path is quoted when it holds spaces, else runs to the next space (the
# gateway's MEDIA_TAG_CLEANUP_RE, without its list of extensions).
MEDIA_RE = re.compile(r"""MEDIA:[ \t]*(?P<path>`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|[^\s)\]>"'`]+)""")
# Only a local target: the gateway fetches http(s) images itself, and anything
# else (a relative link) is not an attachment it would try.
MD_IMAGE_RE = re.compile(r"!\[(?P<alt>[^\]]*)\]\(\s*(?P<path>(?:/|~/)[^)\s]*)\s*\)")
_FENCED_CODE_RE = re.compile(r"```[^\n]*\n.*?```", re.DOTALL)
_INLINE_CODE_RE = re.compile(r"`[^`\n]+`")
_QUOTE_RE = re.compile(r"^>.*$", re.MULTILINE)

WHERE_TO_PUT = "copy it under ~/.hermes/cache/documents and send that path"

Validator = Callable[[str], Optional[str]]


def _validator() -> Optional[Validator]:
    """The gateway's own verdict, once it can be imported in this process."""
    try:
        from gateway.platforms.base import validate_media_delivery_path
    except Exception:  # the CLI: no gateway loaded, or it moved upstream
        return None
    return validate_media_delivery_path


def _normalize(raw: str) -> str:
    """The path a tag names, as the gateway reads it (_normalize_media_tag_path)."""
    path = raw.strip()
    if len(path) >= 2 and path[0] == path[-1] and path[0] in "`\"'":
        path = path[1:-1].strip()
    path = path.lstrip("`\"'").rstrip("`\"',.;:!?)}]")
    return os.path.expanduser(path)


def _under(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def _allowed_locally(path: Path) -> bool:
    for raw in os.environ.get(_ALLOW_DIRS_ENV, "").replace(",", os.pathsep).split(os.pathsep):
        raw = raw.strip()
        if raw and os.path.isabs(os.path.expanduser(raw)):
            if _under(path, Path(os.path.expanduser(raw)).resolve()):
                return True
    return False


def _refused_locally(path: Path) -> bool:
    """The denied-location half of the gateway's policy, for when it cannot be asked."""
    if _allowed_locally(path):
        return False
    home = Path(os.path.expanduser("~")).resolve()
    for prefix in _DENIED_PREFIXES:
        root = Path(prefix).resolve()
        if root != home and _under(path, root):
            return True
    if any(_under(path, (home / sub).resolve()) for sub in _DENIED_HOME):
        return True
    return any(_under(path, (home / ".hermes" / sub).resolve()) for sub in _DENIED_HOME_FILES)


def verdict(raw: str, validate: Optional[Validator] = None) -> Optional[str]:
    """Why the gateway would not attach ``raw``: "relative", "missing" or
    "refused"; None when it would."""
    path = _normalize(raw[len("MEDIA:"):] if raw.upper().startswith("MEDIA:") else raw)
    if not os.path.isabs(path):
        return "relative"
    try:
        resolved = Path(path).resolve(strict=True)
    except (OSError, RuntimeError, ValueError):
        return "missing"
    if not resolved.is_file():
        return "missing"
    check = validate if validate is not None else _validator()
    if check is not None:
        try:
            return None if check(path) else "refused"
        except Exception:
            logger.debug("outbox: the gateway's check failed on %s", path, exc_info=True)
    return "refused" if _refused_locally(resolved) else None


def deliverable(raw: str, validate: Optional[Validator] = None) -> bool:
    """Whether the gateway would attach ``raw`` to the reply."""
    return verdict(raw, validate) is None


def _note(kind: str, raw: str, why: str = "refused") -> str:
    path = _normalize(raw)
    reason = {
        "missing": "no such file",
        "relative": "not an absolute path",
    }.get(why, f"the gateway does not send files from there; {WHERE_TO_PUT}")
    return f"[{kind} not sent: {path} — {reason}]"


def _protected(text: str, validate: Optional[Validator]) -> list[tuple[int, int]]:
    """Code and quotes, which the gateway reads as examples, not attachments.
    A whole tag in inline code is the exception it delivers when it validates."""
    spans = [m.span() for m in _FENCED_CODE_RE.finditer(text)]
    for m in _INLINE_CODE_RE.finditer(text):
        if re.search(r"MEDIA:\s*$", text[max(0, m.start() - 20):m.start()]):
            continue  # MEDIA: `path with spaces`, a quoted path
        inner = m.group(0)[1:-1].strip()
        if inner.upper().startswith("MEDIA:") and verdict(inner, validate) is None:
            continue
        spans.append(m.span())
    spans.extend(m.span() for m in _QUOTE_RE.finditer(text))
    return spans


def rescue(text: str, validate: Optional[Validator] = None) -> Optional[str]:
    """``text`` with each undeliverable attachment replaced by a sentence saying so.

    None when the reply is already honest about its attachments, so the hook
    leaves every other reply untouched.
    """
    if not text or ("MEDIA:" not in text and "](" not in text):
        return None
    protected = _protected(text, validate)
    changed = False

    def swap(kind: str):
        def replace(match: re.Match) -> str:
            nonlocal changed
            if any(start <= match.start() < end for start, end in protected):
                return match.group(0)
            why = verdict(match.group("path"), validate)
            if why is None:
                return match.group(0)
            changed = True
            logger.info("outbox: %s not delivered (%s): %s", kind, why, match.group("path"))
            return _note(kind, match.group("path"), why)
        return replace

    # One pass per pattern on the original text, so the spans stay valid: the
    # two never overlap (an image's target holds no "MEDIA:").
    out, last = [], 0
    matches = sorted(
        [(m, "image") for m in MD_IMAGE_RE.finditer(text)]
        + [(m, "attachment") for m in MEDIA_RE.finditer(text)],
        key=lambda pair: pair[0].start(),
    )
    for match, kind in matches:
        if match.start() < last:
            continue
        out.append(text[last:match.start()])
        out.append(swap(kind)(match))
        last = match.end()
    out.append(text[last:])
    return "".join(out) if changed else None


def on_output(response_text: str = "", **kwargs) -> Optional[str]:
    """The ``transform_llm_output`` hook."""
    try:
        return rescue(response_text)
    except Exception:  # never break a reply over this
        logger.warning("outbox: could not check the reply's attachments", exc_info=True)
        return None


def register(ctx) -> None:
    ctx.register_hook("transform_llm_output", on_output)
