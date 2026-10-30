"""The actions a decision model may choose from, for one page snapshot.

Built as Cua's jev-use builds them (libs/cua-driver/examples/jev-use at
2d974f1843c7343a70affba9d21e7362979edec3, python/sources.py
BrowserSemanticSource): from a ``get_browser_state`` ``semantic_v2``
snapshot's refs, clicked through ``browser_click`` and typed into through
``browser_type``. The model sees only each candidate's ID and description;
the tool and its exact arguments stay here. jev-use's tasks pick their few
controls by hand; a page of any site has hundreds, so the closest to the goal
are offered, with the reserved outcomes, within jev-use's cap (24).
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field
from typing import Any, Mapping

MAX_ACTIONS = 24

DONE = "done"
REOBSERVE = "reobserve"
ABSTAIN = "abstain"
RESERVED = {
    DONE: "The goal is already reached on this page: stop here.",
    REOBSERVE: "The page is still changing (loading, animating): look at it again before acting.",
    ABSTAIN: "None of the other options moves toward the goal: stop and hand back.",
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
class Candidate:
    id: str
    description: str
    tool: str | None = None
    arguments: Mapping[str, Any] = field(default_factory=dict)


def _words(text: str) -> set[str]:
    plain = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()
    return {word for word in re.findall(r"[a-z0-9]+", plain) if len(word) > 2}


def _label(ref: Mapping[str, Any]) -> str:
    name = " ".join(str(ref.get("name") or "").split())
    return name[:80]


def _preview(text: str) -> str:
    flat = " ".join(text.split())
    return flat if len(flat) <= 60 else flat[:57] + "..."


def build(
    snapshot: Mapping[str, Any],
    *,
    goal: str,
    texts: list[str] = (),
    allow_risky: bool = False,
) -> list[Candidate]:
    """The page's actions closest to ``goal``, then the reserved outcomes.

    Every text Hermes wrote may go into every typable field: which one goes
    where is the model's choice, among those closed candidates, so it never
    writes anything itself (jev-use's tasks name their typing candidates the
    same way, sources.py type_text)."""
    target = {"target_id": snapshot["target_id"], "tab_id": snapshot["tab_id"]}
    wanted = _words(goal + " " + " ".join(texts))
    scored: list[tuple[int, int, Candidate]] = []
    for order, ref in enumerate(snapshot.get("refs") or []):
        handle, role, label = ref.get("ref"), str(ref.get("role") or "element"), _label(ref)
        if not handle or not label:
            continue
        actions = set(ref.get("actions") or ["click"])
        closeness = len(wanted & _words(label + " " + role))
        if "click" in actions and (allow_risky or not RISKY.search(label)):
            scored.append((closeness, order, Candidate(
                f"click:{handle}", f'Click the {role} "{label}"',
                "browser_click", {**target, "ref": handle},
            )))
        if "type" in actions and role in TYPABLE:
            for index, text in enumerate(texts):
                scored.append((closeness + 1, order, Candidate(
                    f"type:{handle}:{index}", f'Type "{_preview(text)}" into the {role} "{label}"',
                    "browser_type", {**target, "ref": handle, "text": text, "replace": True},
                )))
    scored.sort(key=lambda item: (-item[0], item[1]))
    chosen = [candidate for _, _, candidate in scored[:MAX_ACTIONS]]
    return chosen + [Candidate(key, description) for key, description in RESERVED.items()]
