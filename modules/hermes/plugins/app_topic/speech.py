"""The notification text and its spoken variant, from a message's final text.

Siri reads a notification aloud as written (Announce Notifications), so the
spoken variant has no markdown, no URL, no code, no emoji, and symbols in
words. It is always derived: a "🔊 …" line Hermes may still write (an old
habit) never reaches Telegram (``outgoing``). A message starting with "📎 " is
written detail, never spoken (docs/app-protocol.md §6).
"""

from __future__ import annotations

import re
import unicodedata
from urllib.parse import urlparse

SPOKEN_MAX = 200
BODY_MAX = 240
SPEAKER = "\U0001f50a"
DETAIL = "\U0001f4ce"

_CODE_BLOCK = re.compile(r"```.*?(?:```|$)", re.S)
_INLINE_CODE = re.compile(r"`([^`\n]*)`")
_MD_LINK = re.compile(r"!?\[([^\]]*)\]\((\S+?)\)")
_URL = re.compile(r"\bhttps?://[^\s<>()\]]*[^\s<>()\].,;:!?'\"]", re.I)
_HTML_TAG = re.compile(r"</?[a-zA-Z][^>]*>")
_HEADING = re.compile(r"^\s{0,3}#{1,6}\s*", re.M)
_QUOTE = re.compile(r"^\s{0,3}>\s?", re.M)
_BULLET = re.compile(r"^\s*(?:[-*+•]|\d+[.)])\s+", re.M)
_EMPHASIS = re.compile(r"(?<!\w)(\*\*|__|\*|_|~~)(?=\S)(.+?)(?<=\S)\1(?!\w)")
_TABLE_RULE = re.compile(r"^\s*\|?\s*:?-{3,}.*$", re.M)
_MEDIA = re.compile(r"^\s*MEDIA:\S+\s*$", re.M)
_FILE_MARK = re.compile(r"\[fichier:\s*(\S+?)\s*\]")
_SPACES = re.compile(r"[ \t]+")
_SENTENCE = re.compile(r"(?<=[.!?…])\s+")

_SYMBOLS = [
    (re.compile(r"(\d)\s*%"), r"\1 percent"),
    (re.compile(r"\s*(?:→|->|⇒|=>)\s*"), " to "),
    (re.compile(r"\s*(?:←|<-)\s*"), " from "),
    (re.compile(r"\s+&\s+"), " and "),
    (re.compile(r"(\d)\s*°C\b"), r"\1 degrees"),
    (re.compile(r"(?<=\d)\s*[x×]\s*(?=\d)"), " by "),
    (re.compile(r"\s*≈\s*"), " about "),
    (re.compile(r"(?<!\w)~(?=\d)"), "about "),
    (re.compile(r"\s*\+\s*(?=\d)"), " plus "),
    (re.compile(r"(?<=\d)\s*-\s*(?=\d)"), " to "),
    (re.compile(r"\$(\d+(?:[.,]\d+)?)"), r"\1 dollars"),
    (re.compile(r"(\d+(?:[.,]\d+)?)\s*€"), r"\1 euros"),
    (re.compile(r"€\s*(\d+(?:[.,]\d+)?)"), r"\1 euros"),
]


def _domain(url: str) -> str:
    host = urlparse(url).hostname or ""
    return host[4:] if host.startswith("www.") else host


def _no_emoji(text: str) -> str:
    out = []
    for ch in text:
        cat = unicodedata.category(ch)
        if cat == "So" or cat == "Cs" or ch in "\ufe0f\u200d" or 0x1F000 <= ord(ch) <= 0x1FAFF:
            continue
        out.append(ch)
    return "".join(out)


def without_speaker(text: str) -> str:
    """The text without any "🔊 …" line."""
    if SPEAKER not in (text or ""):
        return text or ""
    return "\n".join(row for row in text.split("\n") if not row.strip().startswith(SPEAKER)).rstrip()


def is_detail(text: str) -> bool:
    return (text or "").lstrip().startswith(DETAIL)


def outgoing(text: str) -> tuple[str, str | None]:
    """What goes to Telegram: (the message, a written-detail message to send
    after it or None). "🔊" lines are dropped; a reply with a line starting
    with "📎" is cut there, the rest becoming its own "📎 " message, so the
    spoken answer and what is to be read are never one message."""
    text = without_speaker(text)
    if DETAIL not in text or is_detail(text):
        return text, None
    rows = text.split("\n")
    at = next((i for i, row in enumerate(rows) if row.strip().startswith(DETAIL)), None)
    if at is None:
        return text, None
    main = "\n".join(rows[:at]).rstrip()
    rest = "\n".join(rows[at:]).strip()
    detail = DETAIL + " " + rest[len(DETAIL):].lstrip()
    return main, (detail if detail.strip() != DETAIL else None)


def plain(text: str) -> str:
    """Markdown and HTML out, links as their text, code kept as is."""
    text = _MEDIA.sub("", text or "")
    text = _CODE_BLOCK.sub(lambda m: m.group(0).strip("`").split("\n", 1)[-1] if "\n" in m.group(0) else "", text)
    text = _INLINE_CODE.sub(r"\1", text)
    text = _MD_LINK.sub(lambda m: m.group(1) or m.group(2), text)
    text = _HTML_TAG.sub("", text)
    text = _TABLE_RULE.sub("", text)
    text = _HEADING.sub("", text)
    text = _QUOTE.sub("", text)
    text = _BULLET.sub("", text)
    for _ in range(2):
        text = _EMPHASIS.sub(r"\2", text)
    text = text.replace("|", " ")
    lines = [_SPACES.sub(" ", line).strip() for line in text.split("\n")]
    return "\n".join(line for line in lines if line)


def _cut(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    cut = text[: limit - 1]
    space = cut.rfind(" ")
    return (cut[:space] if space > limit // 2 else cut).rstrip(" ,;:") + "…"


def body(text: str) -> str:
    """The notification body: the message as plain text, short."""
    text = without_speaker(text)
    if is_detail(text):
        text = text.lstrip()[len(DETAIL):]
    return _cut(plain(text).replace("\n", " "), BODY_MAX)


def spoken(text: str) -> str:
    """What Siri reads: at most two sentences, nothing that sounds wrong aloud;
    nothing for written detail."""
    if is_detail(text):
        return ""
    sentences = [s for s in _SENTENCE.split(spoken_full(without_speaker(text))) if s.strip()]
    return _cut(" ".join(sentences[:2]), SPOKEN_MAX)


def spoken_full(text: str) -> str:
    """The whole text made speakable, before it is cut to two sentences."""
    text = _MEDIA.sub("", text or "")
    text = _FILE_MARK.sub(lambda m: f" a file from {_domain(m.group(1)) or 'a link'} ", text)
    text = _CODE_BLOCK.sub(" a code block. ", text)
    text = _INLINE_CODE.sub(lambda m: m.group(1) if len(m.group(1)) <= 24 else "a command", text)
    text = _MD_LINK.sub(lambda m: m.group(1) if m.group(1).strip() and not _URL.match(m.group(1))
                        else f"a link to {_domain(m.group(2))}", text)
    text = _URL.sub(lambda m: f"a link to {_domain(m.group(0))}", text)
    text = plain(text)
    text = _no_emoji(text)
    for pattern, repl in _SYMBOLS:
        text = pattern.sub(repl, text)
    # Each line is its own thought: a bullet list reads as sentences.
    lines = [line.strip() for line in text.split("\n") if line.strip()]
    text = " ".join(line if line[-1] in ".!?…:" else line + "." for line in lines)
    text = re.sub(r"[*#`>|\[\]{}]|(?<!\w)_|_(?!\w)", "", text)
    return _SPACES.sub(" ", text).strip()


def question_spoken(kind: str, text: str, summary: str | None, options: list[str]) -> str:
    if kind == "approval":
        # guard's sentence already says what Hermes wants and why it asks, in
        # the owner's language (guard/titles.py): it is the question.
        if summary:
            return _cut(spoken(summary), SPOKEN_MAX)
        # A card guard escalated shows Hermes' label for it, not a command.
        tool = re.fullmatch(r"<(\w+)> \(plugin approval rule\)", (text or "").strip())
        said = spoken(text) if text and not tool else ""
        what = (f"asks to use {tool.group(1).replace('_', ' ')}" if tool
                else f"asks to run {said}" if said else "asks to run a command")
        return _cut(f"Hermes {what}".rstrip(".") + ". Allow?", SPOKEN_MAX)
    head = spoken(text).rstrip(".?!")
    choices = [spoken(o).rstrip(".") for o in options if o and o.lower() != "other"][:4]
    tail = (" Options: " + ", ".join(choices) + ".") if choices else ""
    return _cut(f"Hermes asks: {head}?{tail}", SPOKEN_MAX)
