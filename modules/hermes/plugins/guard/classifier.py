"""The two-stage classifier, its verdict, the denial counters and what the model
is told: Arthur's Pi extension auto-mode (classifier.ts, denials.ts,
messages.ts), on Hermes' decision model.

The Pi extension asks Claude Sonnet 5 for ``<severity>N</severity>`` text.
Hermes is not on the Claude subscription: its classifier is the configured
System One decision model (server.hermes.decision.approval), which answers
choice questions with probabilities. So a stage is one System One request
with two questions, ``verdict`` (allow/block) and ``category`` (the BLOCK
rule), and the block probability stands for the severity: stage 1 clears at
≤ 0.25 (Claude Code's t1 25 of 100), stage 2 blocks above 0.35 (t2 35).
Retries are Claude Code's: 4 on transient errors (backoff 0.5 s doubling,
≤ 8 s), 4 re-asks on an unusable answer; then fail closed. A request the
model refuses (any other 4xx: a prompt over its length limit, a wrong key or
model) is not asked again: it is a configuration error, the same for every
action, and the owner is asked instead (``config_error``).
"""

from __future__ import annotations

import re
import time
from dataclasses import dataclass
from typing import Callable, Optional

from . import prompt as P

MAX_RETRIES = 4


@dataclass(frozen=True)
class Verdict:
    kind: str  # allow | block | parse_failure | unavailable | config_error | too_long
    reason: str
    stage: str = ""
    block_probability: Optional[float] = None
    category: str = ""
    error: str = ""


def _transient(error: str) -> bool:
    return "unreachable" in error or any(f"HTTP {c}" in error for c in ("408", "409", "429")) or "HTTP 5" in error


def _refused(error: str) -> bool:
    """A 4xx other than the transient ones: asking again cannot help."""
    return bool(re.search(r"HTTP 4\d\d", error)) and not _transient(error)


def status_of(error: str) -> str:
    if "HTTP 429" in error:
        return " (rate-limited)"
    if "HTTP 529" in error:
        return " (overloaded)"
    if "HTTP 5" in error:
        return " (server error)"
    if "Timeout" in error or "timed out" in error:
        return " (timed out)"
    if "unreachable" in error:
        return " (connection failed)"
    return ""


def questions(system: str, suffix: str) -> dict:
    names = P.rule_names()
    categories = {"none": "No BLOCK rule matches the action."}
    categories.update({s: name for s, name in names.items()})
    return {
        "verdict": (system + "\n" + suffix, {
            "allow": "The action is allowed: no BLOCK rule matches, or an ALLOW exception or the user's explicit intent clears a SOFT BLOCK.",
            "block": "The action is blocked: it matches a HARD BLOCK rule, or a SOFT BLOCK rule nothing clears.",
        }),
        "category": ("The BLOCK rule the action matches (the most severe one), or none.", categories),
    }


def _stage(ask: Callable, state: dict, system: str, suffix: str, sleep: Callable) -> "tuple[Optional[dict], str]":
    """One stage with retries: (answers, "") or (None, last error)."""
    from .systemone import DecisionError

    error = ""
    for attempt in range(MAX_RETRIES + 1):
        try:
            return ask(state=state, questions=questions(system, suffix)), ""
        except DecisionError as e:
            error = str(e)
            if _refused(error):
                return None, error
            if _transient(error):
                sleep(min(8.0, 0.5 * 2 ** attempt))
            # anything else: an unusable answer, asked again
        except Exception as e:  # noqa: BLE001 - a client bug is no verdict either
            error = f"{type(e).__name__}: {e}"
    return None, error


def _read(answers: dict) -> "tuple[float, str]":
    verdict = answers["verdict"]
    p_block = verdict.probabilities.get("block")
    if p_block is None:
        p_block = 1.0 - verdict.probabilities["allow"] if "allow" in verdict.probabilities else (
            verdict.confidence if verdict.selected_id == "block" else 1.0 - verdict.confidence)
    category = answers.get("category")
    return float(p_block), (category.selected_id if category and category.selected_id != "none" else "")


def classify(ask: Callable, state: dict, system: str, sleep: Callable = time.sleep) -> Verdict:
    """``ask(state=..., questions=...)`` is systemone.ask bound to the model."""
    t = P.thresholds()
    answers, error = _stage(ask, state, system, P.STAGE1, sleep)
    if answers is None:
        if _refused(error):
            return Verdict("config_error", config_error_reason(error), error=error)
        if _transient(error) or not error:
            return Verdict("unavailable", "Classifier unavailable - blocking for safety", error=error)
        return Verdict("parse_failure", cannot_evaluate(), error=error)
    p1, cat1 = _read(answers)
    if p1 <= t["t1"]:
        return Verdict("allow", "Allowed by fast classifier", "fast", p1)
    answers, error = _stage(ask, state, system, P.STAGE2, sleep)
    if answers is None and _refused(error):
        return Verdict("config_error", config_error_reason(error), "thinking", p1, cat1, error)
    if answers is None:
        # After stage 1, a stage-2 failure blocks on stage 1's assessment (and counts).
        return Verdict("block", "Stage 2 classifier error - blocking based on stage 1 assessment (usually transient \u2014 "
                       "retrying often succeeds)", "thinking", p1, cat1, error)
    p2, cat2 = _read(answers)
    if p2 <= t["t2"]:
        return Verdict("allow", "Allowed by classifier", "thinking", p2)
    name = P.rule_names().get(cat2, "")
    return Verdict("block", f"[{name}]" if name else "Blocked by classifier", "thinking", p2, cat2)


def config_error_reason(error: str) -> str:
    return f"Auto mode can't reach its review model: {error}"


def cannot_evaluate() -> str:
    return "Auto mode could not evaluate this action and is blocking it for safety"


# --- denial tracking (Claude Code's 3 consecutive / 20 total) ---

LIMITS = {"consecutive": 3, "total": 20}


@dataclass
class Denials:
    consecutive: int = 0
    total: int = 0

    def allowed(self) -> None:
        self.consecutive = 0

    def blocked(self) -> None:
        self.consecutive += 1
        self.total += 1

    def over_limit(self) -> bool:
        return self.consecutive >= LIMITS["consecutive"] or self.total >= LIMITS["total"]

    def limit_prompt(self, reason: str) -> str:
        """What the owner is asked once a block reaches a limit. Reaching the
        total starts both counts over; the consecutive count starts over too,
        since Hermes' gate does not tell this hook the owner's answer."""
        if self.total >= LIMITS["total"]:
            head = f"{self.total} actions were blocked this session. Please review the transcript before continuing."
            self.total = 0
        else:
            head = f"{self.consecutive} consecutive actions were blocked. Please review the transcript before continuing."
        self.consecutive = 0
        return f"{head}\n\nLatest blocked action: {reason}"


# --- what the model reads when auto mode stops a call (Claude Code's, verbatim
# but for "Claude Code" and the --debug hint, which Hermes has not) ---

WORK_AROUND = (
    "IMPORTANT: You *may* attempt to accomplish this action using other tools that might naturally be used to "
    "accomplish this goal, e.g. using head instead of cat. But you *should not* attempt to work around this denial in "
    "malicious ways, e.g. do not use your ability to run tests to execute non-test actions. You should only try to "
    "work around this restriction in reasonable ways that do not attempt to bypass the intent behind this denial. ")
ESSENTIAL = (
    "If you believe this capability is essential to complete the user's request, first try a safer method. Get as "
    "much of the rest of the task done as you can, then STOP and explain to the user what you were trying to do and "
    "why you need this permission. Let the user decide how to proceed.")
KEEPS_FAILING = "If it keeps failing, continue with other tasks that don't require this action and come back to it later."
READ_ONLY_NOTE = ("Note: reading files, searching code, and other read-only operations do not require the classifier "
                  "and can still be used.")


def blocked_message(reason: str) -> str:
    return (f"Permission for this action was denied by the auto mode classifier. Reason: {reason}. If you have other "
            f"tasks that don't depend on this action, continue working on those. {WORK_AROUND}{ESSENTIAL}")


def no_verdict_message(reason: str) -> str:
    return (f"{reason}. This is not a judgment that the action is unsafe. This is usually transient — wait briefly and "
            f"try this action again as-is; don't rewrite it. {KEEPS_FAILING} {READ_ONLY_NOTE}")


def unavailable_message(model: str, tool: str, status: str) -> str:
    return (f"{model} is temporarily unavailable{status}, so auto mode cannot determine the safety of {tool} right now. "
            f"Wait a moment and then try this action again. {KEEPS_FAILING} {READ_ONLY_NOTE}")
