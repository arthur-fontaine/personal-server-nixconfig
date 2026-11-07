"""The notification text and its spoken variant, from a message's final text.

Siri reads a notification aloud as written (Announce Notifications), so the
spoken variant has no markdown, no URL, no code, no emoji, and symbols in
words. A last line "🔊 <text>" written by Hermes replaces the derived one.
"""

from __future__ import annotations

import re
import unicodedata
from urllib.parse import urlparse

SPOKEN_MAX = 200
BODY_MAX = 240
OVERRIDE = "🔊"

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


def split_override(text: str) -> tuple[str, str | None]:
    """(text without a final "🔊 …" line, that line's text or None)."""
    lines = (text or "").rstrip().split("\n")
    if lines and lines[-1].strip().startswith(OVERRIDE):
        spoken = lines[-1].strip()[len(OVERRIDE):].strip()
        return "\n".join(lines[:-1]).rstrip(), spoken or None
    return text or "", None


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
    text, _ = split_override(text)
    return _cut(plain(text).replace("\n", " "), BODY_MAX)


def spoken(text: str) -> str:
    """What Siri reads: at most two sentences, nothing that sounds wrong aloud."""
    rest, override = split_override(text)
    if override:
        return _cut(override, SPOKEN_MAX)
    sentences = [s for s in _SENTENCE.split(spoken_full(rest)) if s.strip()]
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
        what = summary or spoken(text)
        return _cut(f"Hermes asks to {what[0].lower() + what[1:] if what else 'run a command'}"
                    .rstrip(".") + ". Allow?", SPOKEN_MAX)
    head = spoken(text).rstrip(".?!")
    choices = [spoken(o).rstrip(".") for o in options if o and o.lower() != "other"][:4]
    tail = (" Options: " + ", ".join(choices) + ".") if choices else ""
    return _cut(f"Hermes asks: {head}?{tail}", SPOKEN_MAX)
