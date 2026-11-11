"""Dynamic UI (docs/app-protocol.md §8): json-render specs the app draws natively.

The format is json-render's flat spec (https://json-render.dev,
vercel-labs/json-render packages/core/src/types.ts): {root, elements, state?}.
Component names and props follow @json-render/shadcn's catalog
(packages/shadcn/src/catalog.ts) and the playground's Metric, Icon, BarGraph
and LineGraph, so a spec written for json-render renders in the app; this
module only accepts the part of that catalog the app draws.
"""

from __future__ import annotations

import json

MAX_ELEMENTS = 200
MAX_BYTES = 60_000
MAX_TEXT = 4000
ACTIONS = ("reply", "open", "setState")

# type → (props, takes children). What the tool's description teaches, and what validate() accepts.
CATALOG: dict[str, tuple[str, bool]] = {
    "Card": ("title?, description?", True),
    "Stack": ("direction?: vertical|horizontal, gap?: none|sm|md|lg|xl, align?: start|center|end|stretch, "
              "justify?: start|center|end|between|around", True),
    "Grid": ("columns?: 1-6, gap?: sm|md|lg|xl", True),
    "Separator": ("orientation?: horizontal|vertical", False),
    "Heading": ("text, level?: h1|h2|h3|h4", False),
    "Text": ("text, variant?: body|caption|muted|lead|code", False),
    "Badge": ("text, variant?: default|secondary|destructive|outline", False),
    "Icon": ("name (Lucide, PascalCase: Sun, Cloud, CloudRain, Thermometer, Wind, Droplets, MapPin, Calendar, "
             "Clock, Check, X, AlertTriangle, Info, TrendingUp, TrendingDown…), size?: sm|md|lg, "
             "color?: default|muted|primary|success|warning|danger", False),
    "Image": ("src (https URL), alt", False),
    "Metric": ("label, value, change?, changeType?: positive|negative|neutral, prefix?, suffix?", False),
    "Progress": ("value, max? (default 100), label?", False),
    "Alert": ("title, message?, type?: info|success|warning|error", False),
    "Table": ("columns: [string], rows: [[string]], caption?", False),
    "BarGraph": ("title?, data: [{label, value}]", False),
    "LineGraph": ("title?, data: [{label, value}]", False),
    "Button": ("label, variant?: primary|secondary|danger, disabled?; event press", False),
    "ButtonGroup": ("buttons: [{label, value}], selected?; event change", False),
    "Select": ("label, options: [string], value?; event change", False),
    "Tabs": ("tabs: [{label, value}], defaultValue?, value?; children: one per tab, in order, or each with "
             "visible on the tab's state", True),
}

DESCRIPTION = (
    "Attach a small native UI (a card, metrics, a table, a chart, buttons) to your reply in the owner's app. "
    "Use it when a glance beats prose (weather, figures, comparisons, a choice to make), not for ordinary "
    "answers. Keep it small: one card or a few. Call it, then write your reply as usual: Telegram shows your "
    "text, the app draws this UI in its place.\n"
    "spec is json-render's flat format: {\"root\": key, \"elements\": {key: {\"type\", \"props\", \"children\": "
    "[keys], \"visible\"?, \"on\"?, \"repeat\"?}}, \"state\"?: {…}}. Components (props, ? = optional):\n"
    + "".join(f"- {name}: {props}{' (children)' if children else ''}\n" for name, (props, children) in CATALOG.items())
    + "Any prop may be {\"$state\": \"/json/pointer\"} (read state), {\"$template\": \"Hi ${/user/name}\"}, "
    "{\"$cond\": condition, \"$then\": a, \"$else\": b}; inside a repeat, {\"$item\": \"field\"} and "
    "{\"$index\": true}. repeat: {\"statePath\": \"/days\"} renders the element's children once per item. "
    "visible: true/false, {\"$state\": p} (truthy), {\"$state\": p, \"eq\"|\"neq\"|\"gt\"|\"gte\"|\"lt\"|\"lte\": v}, "
    "\"not\": true inverts, [conditions] = all, {\"$and\": […]}, {\"$or\": […]}.\n"
    "Actions (on: {\"press\"|\"change\": {\"action\", \"params\"}}): reply {text} sends that text to you as "
    "the owner's reply to this message (you get a normal turn, and may answer with a new UI); open {url} "
    "opens a link; setState {statePath, value} changes local state (tabs, toggles). Nothing else.\n"
    "The tool answers with errors to fix, else that the UI waits for your reply. Then reply as usual, short, "
    "with the same key facts (what a reader without the app sees); don't describe the UI, never answer [SILENT]."
)

SCHEMA = {
    "name": "render_ui",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "spec": {"type": "object", "description": "The json-render spec: {root, elements, state?}."},
        },
        "required": ["spec"],
    },
}


KEY_LENGTH = 48


def key(text: str) -> str:
    """What links a UI to its message in the app (protocol §8): the reply's first letters and digits,
    lowercased. The bot and the owner number a private chat's messages each their own way, so the
    message's id can't."""
    import unicodedata

    from .speech import plain

    text = unicodedata.normalize("NFC", plain(text or "").lower())
    return "".join(c for c in text if c.isalnum())[:KEY_LENGTH]


def parse_spec(raw):
    """The spec as an object: models sometimes pass it as a JSON string."""
    if isinstance(raw, str):
        try:
            return json.loads(raw)
        except ValueError:
            return raw
    return raw


def _is_expr(value, key: str) -> bool:
    return isinstance(value, dict) and key in value


def _check_action(where: str, binding, problems: list[str]) -> None:
    if not isinstance(binding, dict) or not isinstance(binding.get("action"), str):
        problems.append(f"{where}: an action is {{\"action\": name, \"params\": {{…}}}}")
        return
    action, params = binding["action"], binding.get("params") or {}
    if action not in ACTIONS:
        problems.append(f"{where}: unknown action {action!r}; use reply, open or setState")
        return
    if not isinstance(params, dict):
        problems.append(f"{where}: params must be an object")
        return
    if action == "reply":
        text = params.get("text")
        if not (isinstance(text, str) and text.strip()) and not isinstance(text, dict):
            problems.append(f"{where}: reply needs params.text, the words sent back to you")
    elif action == "open":
        url = params.get("url")
        if not (isinstance(url, dict) or (isinstance(url, str) and url.startswith(("https://", "http://")))):
            problems.append(f"{where}: open needs params.url, an http(s) link")
    elif action == "setState":
        if not isinstance(params.get("statePath"), (str, dict)) or "value" not in params:
            problems.append(f"{where}: setState needs params.statePath and params.value")


def validate(spec) -> list[str]:
    """What the model must fix, or [] when the app can draw it."""
    if not isinstance(spec, dict):
        return ["spec must be an object {root, elements, state?}"]
    problems: list[str] = []
    elements = spec.get("elements")
    root = spec.get("root")
    if not isinstance(elements, dict) or not elements:
        return ["spec.elements must be a non-empty object of elements by key"]
    if not isinstance(root, str) or root not in elements:
        problems.append(f"spec.root must be the key of an element ({root!r} is not one)")
    if len(elements) > MAX_ELEMENTS:
        problems.append(f"{len(elements)} elements: at most {MAX_ELEMENTS}; keep it small")
    size = len(json.dumps(spec, ensure_ascii=False).encode())
    if size > MAX_BYTES:
        problems.append(f"the spec is {size // 1000} KB: at most {MAX_BYTES // 1000} KB; keep it small")
    if "state" in spec and not isinstance(spec["state"], dict):
        problems.append("spec.state must be an object")
    for key, element in elements.items():
        where = f"elements.{key}"
        if not isinstance(element, dict):
            problems.append(f"{where} must be an object")
            continue
        kind = element.get("type")
        if kind not in CATALOG:
            problems.append(f"{where}: unknown type {kind!r}; use one of {', '.join(CATALOG)}")
        props = element.get("props", {})
        if not isinstance(props, dict):
            problems.append(f"{where}.props must be an object")
        children = element.get("children", [])
        if not isinstance(children, list) or not all(isinstance(c, str) for c in children):
            problems.append(f"{where}.children must be a list of element keys")
            children = []
        for child in children:
            if child not in elements:
                problems.append(f"{where}: child {child!r} is not an element")
        if children and kind in CATALOG and not CATALOG[kind][1]:
            problems.append(f"{where}: a {kind} has no children")
        on = element.get("on")
        if on is not None:
            if not isinstance(on, dict):
                problems.append(f"{where}.on must be an object of event → action")
            else:
                for event, binding in on.items():
                    for i, one in enumerate(binding if isinstance(binding, list) else [binding]):
                        _check_action(f"{where}.on.{event}" + (f"[{i}]" if isinstance(binding, list) else ""),
                                      one, problems)
        repeat = element.get("repeat")
        if repeat is not None and not (isinstance(repeat, dict) and isinstance(repeat.get("statePath"), (str, dict))):
            problems.append(f"{where}.repeat must be {{\"statePath\": \"/pointer\"}}")
    if not problems:
        cycle = _cycle(root, elements)
        if cycle:
            problems.append("children form a cycle: " + " → ".join(cycle))
    return problems


def _cycle(root: str, elements: dict) -> list[str] | None:
    """A path that comes back on itself, from the root; None when the tree is a tree."""
    done: set[str] = set()

    def walk(key: str, path: list[str]) -> list[str] | None:
        if key in path:
            return path[path.index(key):] + [key]
        if key in done:
            return None
        for child in elements.get(key, {}).get("children") or []:
            found = walk(child, path + [key])
            if found:
                return found
        done.add(key)
        return None

    return walk(root, [])
