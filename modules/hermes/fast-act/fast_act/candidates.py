"""The questions a decision model answers about one page snapshot.

Shaped as browser-use's jev-ultrafast asks them (https://github.com/browser-use/jev-ultrafast,
"How it works in a nutshell", https://x.com/gregpr07/status/2100411547290046717):
from the page's element table, one request asks the operation and, for each
operation, its target; the target of the chosen operation is used. The page's
elements are those of a ``get_browser_state`` ``semantic_v2`` snapshot, acted
on through ``browser_click`` and ``browser_type`` as Cua's jev-use does
(libs/cua-driver/examples/jev-use at 2d974f1843c7343a70affba9d21e7362979edec3,
python/sources.py BrowserSemanticSource). The text typed is never the
model's: jev-ultrafast has a small LLM write it, here it is Hermes', given in
full; the model picks which, when there are several.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from typing import Any, Mapping

# jev-use caps a decision at 24 actions.
MAX_TARGETS = 24

CLICK, TYPE, DONE, REOBSERVE, ABSTAIN = "click", "type", "done", "reobserve", "abstain"
OPERATIONS = {
    CLICK: "Click one element of the page.",
    TYPE: "Type text into one field of the page.",
    DONE: "The goal is already reached on this page: stop here.",
    REOBSERVE: "The page is still changing (loading, animating): look at it again before acting.",
    ABSTAIN: "Nothing on this page moves toward the goal: stop and hand back.",
}

# Labels whose click does what cannot be undone, offered only when the caller
# allows it (jev-use leaves delete or send out unless the task allows them).
RISKY = re.compile(
    r"\b(send|delete|remove|publish|post|share|pay|buy|order|purchase|confirm|submit|unfollow|block|"
    r"envoyer|supprimer|retirer|publier|partager|payer|acheter|commander|confirmer|valider|bloquer)\b",
    re.IGNORECASE,
)
TYPABLE = {"textbox", "searchbox", "combobox", "textarea", "input"}


@dataclass(frozen=True)
class Element:
    id: str
    description: str
    ref: str


@dataclass(frozen=True)
class Questions:
    """One step's questions, and how to act on each answer."""

    target: Mapping[str, str]
    clickable: Mapping[str, Element]
    typable: Mapping[str, Element]
    texts: tuple[str, ...]

    def criteria(self) -> dict[str, tuple[str, dict[str, str]]]:
        operations = dict(OPERATIONS)
        if not self.clickable:
            operations.pop(CLICK)
        if not self.typable:
            operations.pop(TYPE)
        questions = {"operation": ("Which operation moves toward the goal now?", operations)}
        if self.clickable:
            questions["click_target"] = (
                "If the operation is a click: which element?",
                {key: e.description for key, e in self.clickable.items()},
            )
        if self.typable:
            questions["type_target"] = (
                "If the operation is typing: into which field?",
                {key: e.description for key, e in self.typable.items()},
            )
        if len(self.texts) > 1:
            questions["text"] = (
                "If the operation is typing: which of these texts goes there?",
                {f"t{index}": f'"{preview(text)}"' for index, text in enumerate(self.texts)},
            )
        return questions

    def click(self, element_id: str) -> tuple[str, dict[str, Any]]:
        return "browser_click", {**self.target, "ref": self.clickable[element_id].ref}

    def type(self, element_id: str, text: str) -> tuple[str, dict[str, Any]]:
        return "browser_type", {**self.target, "ref": self.typable[element_id].ref, "text": text, "replace": True}


def _words(text: str) -> set[str]:
    plain = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()
    return {word for word in re.findall(r"[a-z0-9]+", plain) if len(word) > 2}


def _label(ref: Mapping[str, Any]) -> str:
    return " ".join(str(ref.get("name") or "").split())[:80]


def preview(text: str) -> str:
    flat = " ".join(text.split())
    return flat if len(flat) <= 60 else flat[:57] + "..."


def build(
    snapshot: Mapping[str, Any],
    *,
    goal: str,
    texts: tuple[str, ...] | list[str] = (),
    allow_risky: bool = False,
) -> Questions:
    """The page's elements closest to ``goal``, within jev-use's cap per question."""
    wanted = _words(goal + " " + " ".join(texts))
    clickable: list[tuple[int, int, Element]] = []
    typable: list[tuple[int, int, Element]] = []
    for order, ref in enumerate(snapshot.get("refs") or []):
        handle, role, label = ref.get("ref"), str(ref.get("role") or "element"), _label(ref)
        if not handle or not label:
            continue
        actions = set(ref.get("actions") or ["click"])
        closeness = len(wanted & _words(label + " " + role))
        element = Element(f"e{order}", f'the {role} "{label}"', str(handle))
        if "type" in actions and role in TYPABLE:
            typable.append((closeness, order, element))
        if "click" in actions and (allow_risky or not RISKY.search(label)):
            clickable.append((closeness, order, element))

    def closest(items: list[tuple[int, int, Element]]) -> dict[str, Element]:
        items.sort(key=lambda item: (-item[0], item[1]))
        return {element.id: element for _, _, element in items[:MAX_TARGETS]}

    return Questions(
        target={"target_id": snapshot["target_id"], "tab_id": snapshot["tab_id"]},
        clickable=closest(clickable),
        typable=closest(typable),
        texts=tuple(texts),
    )
