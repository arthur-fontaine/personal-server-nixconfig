"""The classifier's request, built to fit the decision model's prompt limit.

A System One model refuses a prompt over its length (Baseten's mammoth-27b:
16,000 tokens, HTTP 422, "prompts are never truncated"), so the request is
fitted here, by construction, under ``max_prompt_tokens`` as
prompt.estimate_tokens counts it (an over-estimate):

1. the instructions: Claude Code's verbatim prompt when the request still has
   room for a conversation with it, else prompts/compact.md;
2. the action under review, with its meta line: always whole; an action too
   long to fit is ``TooLong`` (the owner is asked);
3. the owner's latest message: always kept, its middle cut if it alone
   would not fit;
4. the conversation, newest first, until the room left; an older line no
   longer fits and it and everything before it are replaced by one
   ``{"omitted": …}`` line; one very long line has its middle cut;
5. the owner's AGENTS.md (Claude Code's CLAUDE.md): what room is left, at
   most a third of what followed the action, cut at the end.

The whole body is measured last and lines dropped until it fits, so the
estimate holds whatever the pieces' rounding.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Callable

from . import prompt as P
from .transcript import line

# The longer of the two stages' instructions is measured.
STAGES = (P.STAGE1, P.STAGE2)
# What the verbatim prompt must leave for the conversation to be chosen.
ROOM_FOR_CONVERSATION = 3000
# A line of the conversation never takes more than this share of its room.
LINE_SHARE = 4
CONTEXT_SHARE = 3
CUT = "[… cut …]"
CONTEXT_CUT = "\n[… the rest is left out for length]"


class TooLong(Exception):
    """The action alone does not fit the model's prompt."""


@dataclass(frozen=True)
class Request:
    state: dict
    system: str
    variant: str  # verbatim | compact
    tokens: int  # the whole body, estimated
    omitted: int  # conversation lines left out
    context_cut: bool


def body(model: str, state: dict, system: str, questions: Callable) -> dict:
    stages = [questions(system, suffix) for suffix in STAGES]
    longest = max(stages, key=lambda q: sum(len(i) + len(json.dumps(c)) for i, c in q.values()))
    return {"model": model, "state": state,
            "questions": {k: {"type": "choice", "instructions": i, "criteria": dict(c)} for k, (i, c) in longest.items()}}


def measure(value) -> int:
    return P.estimate_tokens(json.dumps(value, ensure_ascii=False))


def cost(text: str) -> int:
    """A piece of a JSON string: its escaped length."""
    return P.estimate_tokens(json.dumps(text, ensure_ascii=False)) - 1


def cut_middle(text: str, tokens: int) -> str:
    """``text`` cut in its middle to about ``tokens``, its ends kept."""
    if cost(text) <= tokens:
        return text
    keep = max(0, int(tokens * P.BYTES_PER_TOKEN * 0.9) - len(CUT))
    # Bytes, not characters, bound the estimate: shrink until it fits.
    while keep > 0:
        head, tail = text[:keep // 2], text[len(text) - keep // 2:] if keep // 2 else ""
        out = head + CUT + tail
        if cost(out) <= tokens:
            return out.rstrip("\n") + "\n" if text.endswith("\n") else out
        keep = keep * 9 // 10
    return CUT + "\n"


def cut_end(text: str, tokens: int) -> str:
    if cost(text) <= tokens:
        return text
    keep = int(tokens * P.BYTES_PER_TOKEN * 0.9)
    while keep > 0:
        out = text[:keep] + CONTEXT_CUT
        if cost(out) <= tokens:
            return out
        keep = keep * 9 // 10
    return ""


def latest_owner_line(lines: list) -> int:
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].startswith('{"user":'):
            return i
    return -1


def omitted_line(n: int) -> str:
    return line("omitted", f"{n} earlier entr{'y' if n == 1 else 'ies'} left out for length")


def build(*, budget: int, model: str, lines: list, action: str, meta: str, context: str,
          wrap_context: Callable[[str], str], rules: dict, identity: str, questions: Callable) -> Request:
    """``context`` is the raw AGENTS.md text, ``wrap_context`` frames it."""

    def assemble(system: str, kept: list, context_text: str) -> dict:
        state = {"transcript": "<transcript>\n" + "".join(kept) + meta + action + "</transcript>\n"}
        if context_text:
            state["user_configuration"] = wrap_context(context_text)
        return body(model, state, system, questions)

    verbatim = P.build_system_prompt(rules, identity)
    system, variant = verbatim, "verbatim"
    if measure(assemble(verbatim, [], "")) + ROOM_FOR_CONVERSATION > budget:
        system, variant = P.build_system_prompt(rules, identity, compact=True), "compact"
    fixed = measure(assemble(system, [], ""))
    if fixed > budget:
        raise TooLong(f"the action alone is about {cost(action)} tokens: with the review model's instructions, "
                      f"{fixed}, over the {budget} it reads")
    room = budget - fixed

    # The owner's latest message, kept whatever its length.
    owner = latest_owner_line(lines)
    owner_line = cut_middle(lines[owner], room) if owner >= 0 else ""
    room -= cost(owner_line)

    # The conversation, newest first, leaving AGENTS.md its share.
    wrapped = cost(wrap_context("")) if context else 0
    context_room = min(cost(context) + wrapped, room // CONTEXT_SHARE) if context else 0
    convo_room = room - context_room
    per_line = max(200, convo_room // LINE_SHARE)
    kept: list = []  # (index, text), newest first
    for i in range(len(lines) - 1, -1, -1):
        if i == owner:
            continue
        text = cut_middle(lines[i], per_line)
        c = cost(text)
        if c > convo_room:
            break
        kept.append((i, text))
        convo_room -= c
    if owner >= 0:
        kept.append((owner, owner_line))

    def ordered(entries: list) -> list:
        entries = sorted(entries)
        out, expected = [], 0
        for i, text in entries:
            if i > expected:
                out.append(omitted_line(i - expected))
            out.append(text)
            expected = i + 1
        return out, len(lines) - len(entries)

    # AGENTS.md: its share and what the conversation left.
    context_text = ""
    if context:
        context_text = cut_end(context, max(0, context_room + convo_room - wrapped - 1))

    # Measured whole: drop the oldest kept line (never the owner's), then
    # AGENTS.md, until it fits.
    while True:
        out, omitted = ordered(kept)
        request = assemble(system, out, context_text)
        tokens = measure(request)
        if tokens <= budget:
            return Request(request["state"], system, variant, tokens, omitted, context_text != context)
        droppable = sorted(i for i, _ in kept if i != owner)
        if droppable:
            kept = [(i, t) for i, t in kept if i != droppable[0]]
        elif context_text:
            context_text = cut_end(context_text, max(0, cost(context_text) - (tokens - budget) - 50))
        elif owner >= 0 and cost(owner_line) > 200:
            owner_line = cut_middle(owner_line, cost(owner_line) - (tokens - budget) - 50)
            kept = [(i, owner_line if i == owner else t) for i, t in kept]
        else:
            raise TooLong(f"the request is about {tokens} tokens, over the {budget} the review model reads")
