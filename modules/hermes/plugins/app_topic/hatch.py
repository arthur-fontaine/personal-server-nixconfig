"""Hatching a pet from ONE image: the whole sprite sheet in a single call,
sliced with Hermes' own deterministic tools, with a per-row fallback and a
per-pet cost budget.

Hermes' own hatch (agent/pet/generate/orchestrate.py) draws a base look, then
one strip per state, 4 at a time, 3 attempts each: ≥ 9 images, about $2.40 a
pet with gpt-image on OpenRouter, and OpenRouter refuses a request whose
possible cost would cross the key's limit, so a $2 key could not hatch one.
Here (docs/app.md, Pets):

1. one call draws the 9 Codex states as a 9-row grid on a flat chroma key,
   grounded on a layout guide drawn here (rows' frame counts, construction
   marks the model must not copy); the first idle frame is the canonical look;
2. Hermes' atlas code slices each row band into frames, normalizes, composes
   and validates the 1536×1872 atlas; running-left is mirrored from
   running-right when the sheet's is unusable or faces the wrong way;
3. a row that fails is redrawn alone (Hermes' row prompt, at quality medium,
   grounded on the sheet's idle frame), at most MAX_ROW_REPAIRS rows;
4. every call is checked against the budget first, one call at a time
   (OpenRouter reserves the possible cost of each request in flight), and
   the first account-level refusal stops everything.
"""

from __future__ import annotations

import json
import logging
import re
import shutil
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

logger = logging.getLogger("app_topic")

DEFAULT_MAX_COST = 0.60
MAX_ROW_REPAIRS = 3
SHEET_QUALITY = "high"
ROW_QUALITY = "medium"
# The sheet's ratio: 9 rows of up to 8 frames (atlas 1536×1872, 0.82) fit 3:4
# best among what gpt-image takes (1:1, 3:2, 2:3, 4:3, 3:4, 16:9, 9:16, 21:9).
SHEET_ASPECT = ("portrait", "3:4")
GUIDE_SIZE = (1152, 1536)
CHROMA = (255, 0, 255)
_GUIDE_MARK = (150, 0, 150)

# Cost of one image before any is measured, in USD: gpt-image-2.6-sunburst at
# quality auto drew a 1024×1024 base for $0.26 on OpenRouter (the first hatch,
# 2026-11). Output tokens scale with area and quality (OpenAI's gpt-image
# token table: low ≈ 7 %, medium ≈ 27 % of high); a reference image adds input
# tokens. Once a call reports its cost, later estimates follow it.
_SQUARE_HIGH = 0.26
_QUALITY_FACTOR = {"low": 0.07, "medium": 0.27, "high": 1.0, "auto": 1.0, "xhigh": 1.6, "max": 2.2}
# 3:4 may be drawn at 1152×1536 (1.7 × 1024²): priced as such.
_AREA = {"square": 1.0, "portrait": 1.7, "landscape": 1.7}
_PER_REFERENCE = 0.02
_CALIBRATED_MARGIN = 1.15


class ProviderRefused(RuntimeError):
    """The image provider refused for a reason no retry changes (a key, its
    credit or limit): the message says what the owner can do."""

    def __init__(self, message: str, report: dict | None = None) -> None:
        super().__init__(message)
        self.report = report or {}


class HatchFailed(RuntimeError):
    """No pet: the message says why, ``report`` what was spent and tried."""

    def __init__(self, message: str, report: dict | None = None) -> None:
        super().__init__(message)
        self.report = report or {}


class OverBudget(RuntimeError):
    pass


# An account-level refusal: asking again, or for the next row, gets the same
# answer. The OpenRouter provider marks 401/403 non-retryable but 402
# retryable on its model chain (plugins/image_gen/openrouter,
# _IMAGE_API_FALLBACK_STATUSES).
_REFUSED = re.compile(r"\b40[123]\b|key limit|quota|insufficient|credits?\b|billing|payment required|"
                      r"rejected the api key|unauthori[sz]ed|forbidden", re.I)


def refusal(result) -> str:
    """The provider's own words when ``result`` (an image provider's answer) is
    an account-level refusal, else ""."""
    if not isinstance(result, dict) or result.get("success"):
        return ""
    error = str(result.get("error") or "")
    if result.get("error_type") == "auth_error" or _REFUSED.search(error):
        return " ".join(error.split())
    return ""


def plain_refusal(provider: str, error: str) -> str:
    """What happened and what the owner can do, in plain words."""
    who = {"openrouter": "OpenRouter", "openai": "OpenAI"}.get(provider, provider or "The image provider")
    where = "https://openrouter.ai/settings/keys" if provider == "openrouter" else "the provider's dashboard"
    limit = re.search(r"\$([\d.]+) of \$([\d.]+) used(?:; resets (\d{4}-\d\d-\d\d))?", error)
    if "limit" in error.lower() and limit:
        resets = f", it resets on {limit.group(3)}" if limit.group(3) else ""
        what = (f"{who} refused: the API key's spending limit is used up (${limit.group(1)} of ${limit.group(2)}"
                f"{resets}).")
    elif re.search(r"\b402\b|insufficient|credits?\b|billing|payment required|quota", error, re.I):
        what = f"{who} refused: the account has no credit left for images."
    elif re.search(r"\b401\b|rejected the api key|unauthori[sz]ed", error, re.I):
        what = f"{who} refused the API key."
    else:
        what = f"{who} refused the request ({error[:200]})."
    return (f"{what} Nothing more was drawn and it was not retried. To fix it, raise the key's limit or add "
            f"credit at {where}, or choose another pet image provider in the bootstrap (App \u00b7 Hermes' side "
            "\u2192 Pets \u00b7 image provider).")


def estimate(aspect: str, quality: str | None, references: int) -> float:
    """A pessimistic price for one image before any call reported one."""
    factor = _QUALITY_FACTOR.get(quality or "auto", 1.0)
    return _SQUARE_HIGH * _AREA.get(aspect, 1.5) * factor + _PER_REFERENCE * references


@dataclass
class Budget:
    """What a hatch may spend, and what it has: reported costs where the
    provider gives them, estimates otherwise."""

    limit: float
    spent: float = 0.0
    reported: float = 0.0
    estimated: float = 0.0
    scale: float | None = None  # reported ÷ estimate, from the first call that reported its cost
    calls: list = field(default_factory=list)

    def price(self, aspect: str, quality: str | None, references: int) -> float:
        raw = estimate(aspect, quality, references)
        return raw * self.scale * _CALIBRATED_MARGIN if self.scale else raw

    def check(self, what: str, price: float) -> None:
        if self.spent + price > self.limit + 1e-9:
            raise OverBudget(f"{what} would cost about ${price:.2f}, and ${self.spent:.2f} of the "
                             f"${self.limit:.2f} budget is spent")

    def charge(self, what: str, raw: float, price: float, result: dict) -> None:
        cost = result.get("cost_usd") if isinstance(result, dict) else None
        if isinstance(cost, (int, float)) and not isinstance(cost, bool):
            self.reported += cost
            self.spent += cost
            if self.scale is None and raw > 0:
                self.scale = cost / raw
            charged, how = float(cost), "reported"
        elif isinstance(result, dict) and (result.get("success") or result.get("error_type") == "timeout"):
            # A timed-out request may have been billed; a refused one was not.
            self.estimated += price
            self.spent += price
            charged, how = price, "estimated"
        else:
            charged, how = 0.0, "not billed"
        self.calls.append({"what": what, "cost": round(charged, 4), "how": how})

    def summary(self) -> dict:
        return {"spent": round(self.spent, 4), "reported": round(self.reported, 4),
                "estimated": round(self.estimated, 4), "limit": self.limit, "calls": self.calls}


class StopOnRefusal:
    """The image provider, answering every call after an account-level refusal
    with that refusal, without asking again."""

    def __init__(self, provider) -> None:
        self._provider = provider
        self.refused = ""

    def generate(self, prompt, **kwargs):
        if self.refused:
            return {"success": False, "error": self.refused, "error_type": "auth_error"}
        result = self._provider.generate(prompt, **kwargs)
        why = refusal(result)
        if why:
            logger.error("app_topic: the pets' image provider refused (%s); no more calls for this pet", why)
            self.refused = why
        return result

    def __getattr__(self, name):
        return getattr(self._provider, name)


def openrouter_knobs(provider) -> None:
    """Let Hermes' OpenRouter plugin send ``quality`` and an exact ratio to a
    model its curated table lacks (gpt-image-2.6-sunburst…): it drops every
    knob a model does not declare (_build_image_api_payload). The declaration
    comes from OpenRouter's own catalog (GET /images/models,
    supported_parameters), added to the plugin's table for this process."""
    module = sys.modules.get(type(provider).__module__)
    table = getattr(module, "_IMAGE_API_MODELS", None)
    if table is None:
        return
    try:
        model = provider._resolve_model()
        if not model or model in table or model in getattr(module, "_CHAT_ONLY_MODELS", ()):
            return
        api_key, base_url = provider._credentials()
        catalog = dict(module._get_catalog(base_url, "/images/models", api_key, (10.0, 20.0)))
    except Exception:
        logger.debug("app_topic: no image catalog for the pet's model", exc_info=True)
        return
    params = (catalog.get(model) or {}).get("supported_parameters") or {}
    if not params:
        return

    def values(name):
        return tuple((params.get(name) or {}).get("values") or ())

    refs = params.get("input_references") or {}
    table[model] = module._image_api_model(
        model, "from OpenRouter's image catalog (app_topic)", aspect_ratios=values("aspect_ratio"),
        resolutions=values("resolution"), quality=values("quality"), background=values("background"),
        output_format=values("output_format"), compression="output_compression" in params,
        seed="seed" in params, max_n=int((params.get("n") or {}).get("max") or 1),
        max_refs=int(refs.get("max") or 1))
    logger.info("app_topic: %s declared from OpenRouter's catalog: %s", model, sorted(params))


# ── the sheet ───────────────────────────────────────────────────────────

def layout_guide(size: tuple[int, int] = GUIDE_SIZE):
    """The sheet's layout: 9 row bands, each split into its row's frame count,
    on the chroma key; outlines, centre crosses and baselines in a darker
    magenta. A copied outline spans its band, so Hermes' extraction erases
    it as a long thin line (atlas._erase_long_axis_lines)."""
    from PIL import Image, ImageDraw

    from agent.pet.generate import atlas

    w, h = size
    image = Image.new("RGB", size, CHROMA)
    draw = ImageDraw.Draw(image)
    band = h / len(atlas.ROW_SPECS)
    for index, (_state, _row, count) in enumerate(atlas.ROW_SPECS):
        top, bottom = round(index * band), round((index + 1) * band)
        cell = w / count
        for col in range(count):
            left, right = round(col * cell), round((col + 1) * cell)
            draw.rectangle([left + 3, top + 3, right - 4, bottom - 4], outline=_GUIDE_MARK, width=2)
            cx, cy = (left + right) // 2, (top + bottom) // 2
            draw.line([(cx - 8, cy), (cx + 8, cy)], fill=_GUIDE_MARK, width=2)
            draw.line([(cx, cy - 8), (cx, cy + 8)], fill=_GUIDE_MARK, width=2)
            base = bottom - round(band * 0.1)
            draw.line([(left + round(cell * 0.2), base), (right - round(cell * 0.2), base)], fill=_GUIDE_MARK, width=1)
    return image


# Hermes' "running" row asks for "focused active work … concentrating, busy
# energy": models draw it as a frown, and the app shows that row whenever
# Hermes works (an angry pet on the lock screen). Ours keeps the focus and
# asks for a calm, content face.
ACTIONS = {
    "running": ("calm, happy focused work IN PLACE (NOT walking or foot-running): holding a tiny hammer in one "
                "hand, raising it and tapping it down in a clear rhythm across the frames (big, readable arm "
                "motion: hammer up high in some frames, down in others), eyes on the work, a content face with "
                "a small smile; never angry, frowning, furrowed or annoyed. This row MAY add this one small "
                "hammer as a prop, held in the hand; no other props. Clearly different from 'waiting' (hands "
                "still, looking up)"),
}


def action(state: str) -> str:
    from agent.pet.generate import prompts

    return ACTIONS.get(state) or prompts.STATE_ACTIONS[state]


def row_prompt(state: str, count: int, concept: str, style: str = "auto") -> str:
    """Hermes' row prompt (agent/pet/generate/prompts.py), with our action for
    the states we word differently: it inserts the action verbatim."""
    from agent.pet.generate import prompts

    text = prompts.build_row_prompt(state, count, concept, style=style)
    return text.replace(prompts.STATE_ACTIONS[state], action(state)) if state in ACTIONS else text


def sheet_prompt(concept: str, style: str = "auto") -> str:
    from agent.pet.generate import atlas, prompts

    concept = (concept or "a distinctive mascot creature").strip()
    rows = " ".join(
        f"Row {i + 1}, {state}: {count} frames of {action(state)}."
        for i, (state, _row, count) in enumerate(atlas.ROW_SPECS))
    return (
        f"A sprite sheet of ONE original mascot pet character: {concept}. Honor the requested tone and mood "
        "exactly while staying non-graphic. Compact whole-body silhouette that reads at small size, clear face, "
        "simple consistent palette. The FIRST frame of the first row is the canonical look: a neutral, "
        "front-facing standing pose; every other frame is exactly the same character (same species, face, "
        "colors, markings, proportions, props, size). "
        "LAYOUT: follow the attached layout guide exactly: 9 horizontal rows, top to bottom, each row one "
        "animation read left to right, one pose centered in each of the guide's cells, so rows have different "
        f"frame counts. {rows} "
        "The guide is an invisible construction reference: draw NONE of its outlines, crosses, lines, cells or "
        "colors, no grid, no dividers, no labels, no numbers. Every pose stays fully inside its own cell with "
        "empty background around it: poses never touch, overlap or share a shadow; nothing is cropped. Same "
        "scale in every frame, feet on the same invisible baseline in each row. "
        "Effects only if attached to the body (no detached sparkles, tears, smoke, stars, punctuation, motion "
        "lines, speed lines, dust, wave marks, shadows, glows, floor or ground lines). running-right faces and "
        "travels right, running-left faces and travels left; running is working in place, not foot-running. "
        "BACKGROUND: the whole sheet is ONE flat, even, pure hot magenta #FF00FF (pure green #00FF00 only if the "
        "character has magenta), with no gradient, texture, scenery, border or panel; that color appears nowhere "
        "on the character. No text, no UI."
        f"{prompts.style_hint(style)}"
    )


def row_bands(keyed, rows: int) -> list[tuple[int, int]]:
    """(top, bottom) of each row in the keyed sheet: cut where the least
    sprite mass is, near each expected boundary, so a sheet whose rows drift
    a little from the guide is still cut between poses."""
    from PIL import Image

    h = keyed.height
    profile = list(keyed.getchannel("A").resize((1, h), Image.BILINEAR).getdata())
    band = h / rows
    window = max(2, round(band * 0.3))
    cuts = [0]
    for i in range(1, rows):
        expected = round(i * band)
        lo, hi = max(cuts[-1] + 1, expected - window), min(h - 1, expected + window)
        cuts.append(min(range(lo, hi + 1), key=lambda y: (profile[y], abs(y - expected))) if lo <= hi else expected)
    cuts.append(h)
    return list(zip(cuts, cuts[1:]))


def _sheet_key(sheet) -> tuple[int, int, int]:
    from collections import Counter

    rgb = sheet.convert("RGB")
    w, h = rgb.size
    points = [(x, y) for x in (0, w // 2, w - 1) for y in (0, h - 1)] + [(0, h // 2), (w - 1, h // 2)]
    return Counter(rgb.getpixel(p) for p in points).most_common(1)[0][0]


def slice_sheet(sheet) -> tuple[dict[str, list], dict[str, str]]:
    """Frames per state (Hermes' extraction, unfitted), and why each row that
    failed did."""
    from agent.pet.generate import atlas

    sheet = atlas._load_rgba(sheet)
    key = _sheet_key(sheet)
    keyed = atlas.remove_background(sheet, chroma_key=key)
    frames, errors = {}, {}
    for (state, _row, count), (top, bottom) in zip(atlas.ROW_SPECS, row_bands(keyed, len(atlas.ROW_SPECS))):
        band = sheet.crop((0, top, sheet.width, bottom))
        try:
            frames[state] = atlas.extract_strip_frames(band, count, chroma_key=key, method="components", fit=False)
        except Exception as error:
            errors[state] = str(error)
    return frames, errors


def faces_wrong_way(left: list, right: list) -> bool:
    """True when running-left looks more like running-right than like its
    mirror (it faces right)."""
    from PIL import Image, ImageChops, ImageOps

    def mask(frame):
        frame = frame.convert("RGBA")
        box = frame.getbbox()
        alpha = frame.getchannel("A").crop(box) if box else frame.getchannel("A")
        return alpha.resize((48, 52), Image.BILINEAR)

    def distance(a, b):
        return sum(ImageChops.difference(a, b).getdata())

    same = mirrored = 0
    for l, r in zip(left, right):
        lm, rm = mask(l), mask(r)
        same += distance(lm, rm)
        mirrored += distance(lm, ImageOps.mirror(rm))
    return same < mirrored


def compose(frames: dict[str, list]):
    """Hermes' normalization, atlas and validation; errors naming a state."""
    from agent.pet.generate import atlas

    sheet = atlas.compose_atlas(atlas.normalize_cells(frames))
    validation = atlas.validate_atlas(sheet)
    named = {}
    for error in validation["errors"]:
        if match := re.search(r"state '([^']+)'", error):
            named.setdefault(match.group(1), error)
    return sheet, validation, named


def contact_sheet(atlas_image):
    """The atlas on a neutral checker with its cell grid, for a person to look at."""
    from PIL import Image, ImageDraw

    from agent.pet.generate import atlas

    w, h = atlas_image.size
    out = Image.new("RGBA", (w, h), (60, 60, 64, 255))
    draw = ImageDraw.Draw(out)
    for y in range(0, h, 16):
        for x in range(0, w, 16):
            if (x // 16 + y // 16) % 2:
                draw.rectangle([x, y, x + 15, y + 15], fill=(72, 72, 78, 255))
    out.alpha_composite(atlas_image.convert("RGBA"))
    for col in range(1, w // atlas.CELL_WIDTH):
        draw.line([(col * atlas.CELL_WIDTH, 0), (col * atlas.CELL_WIDTH, h)], fill=(120, 120, 130, 255))
    for row in range(1, h // atlas.CELL_HEIGHT):
        draw.line([(0, row * atlas.CELL_HEIGHT), (w, row * atlas.CELL_HEIGHT)], fill=(120, 120, 130, 255))
    return out


def idle_reference(frame, work: Path) -> Path:
    """The canonical look for redrawn rows: the first idle frame, keyed, on
    the chroma key, large enough to read."""
    from PIL import Image

    idle = frame.convert("RGBA")
    idle = idle.crop(idle.getbbox() or (0, 0, idle.width, idle.height))
    scale = max(1, 384 // max(idle.size))
    idle = idle.resize((idle.width * scale, idle.height * scale), Image.Resampling.NEAREST)
    reference = Image.new("RGBA", (idle.width + 128, idle.height + 128), CHROMA + (255,))
    reference.alpha_composite(idle, (64, 64))
    path = work / "idle-reference.png"
    reference.convert("RGB").save(path)
    return path


def atlas_frames(sheet) -> dict[str, list]:
    """An existing atlas cut back into its frames, row by row."""
    from agent.pet.generate import atlas

    image = atlas._load_rgba(sheet)
    w, h = atlas.CELL_WIDTH, atlas.CELL_HEIGHT
    return {state: [image.crop((c * w, row * h, (c + 1) * w, (row + 1) * h)) for c in range(count)]
            for state, row, count in atlas.ROW_SPECS}


def redraw(sheet, states: list[str], concept: str, *, sprite, work: Path, max_cost: float = DEFAULT_MAX_COST,
           style: str = "auto"):
    """Redraws *states* of an existing pet's atlas alone (one image each, at
    the row quality, grounded on its idle frame); the other rows stay as they
    are. Returns ``(atlas, report)``; raises like ``hatch``."""
    from agent.pet.generate import atlas

    work.mkdir(parents=True, exist_ok=True)
    known = [s for s, _r, _c in atlas.ROW_SPECS]
    unknown = [s for s in states if s not in known]
    if unknown or not states:
        raise HatchFailed(f"unknown rows: {', '.join(unknown) or 'none given'} (rows: {', '.join(known)})")
    guarded = sprite.provider if isinstance(sprite.provider, StopOnRefusal) else StopOnRefusal(sprite.provider)
    run = _Run(type(sprite)(name=sprite.name, provider=guarded, supports_references=sprite.supports_references),
               Budget(max_cost), work)
    report: dict = {"path": "rows", "repaired_rows": list(states)}
    started = time.monotonic()

    def fail(message: str):
        report.update(error=message, budget=run.budget.summary(), seconds=round(time.monotonic() - started, 1))
        if guarded.refused:
            raise ProviderRefused(plain_refusal(sprite.name, guarded.refused), report)
        raise HatchFailed(message, report)

    frames = atlas_frames(sheet)
    idle_ref = idle_reference(frames["idle"][0], work)
    counts = {s: c for s, _r, c in atlas.ROW_SPECS}
    for state in states:
        try:
            strip = run.draw(f"row-{state}", row_prompt(state, counts[state], concept, style),
                             references=[idle_ref], aspect=("landscape", None), quality=ROW_QUALITY)
        except OverBudget as error:
            fail(f"the {state} row could not be redrawn within the budget: {error}")
        if strip is None:
            fail(f"the {state} row could not be redrawn: the provider returned no image")
        try:
            frames[state] = atlas.extract_strip_frames(strip, counts[state], method="auto", fit=False)
        except Exception as error:
            fail(f"the redrawn {state} row is unusable: {error}")
        if state == "running-right" and "running-left" not in states:
            frames["running-left"] = atlas.mirror_frames(frames[state])
    # Hermes' normalization scales every row by one factor keyed to all of
    # them: the new rows come out at the pet's size, but the kept rows would
    # move a little too. Only the redrawn rows are taken from it.
    normalized, _validation, _named = compose(frames)
    redrawn = set(states) | ({"running-left"} if "running-right" in states else set())
    result = atlas._load_rgba(sheet).copy()
    w, h = atlas.CELL_WIDTH, atlas.CELL_HEIGHT
    for state, row, _count in atlas.ROW_SPECS:
        if state in redrawn:
            box = (0, row * h, atlas.ATLAS_WIDTH, (row + 1) * h)
            result.paste(normalized.crop(box), box[:2])
    validation = atlas.validate_atlas(result)
    if not validation["ok"]:
        fail("; ".join(validation["errors"]) or "atlas validation failed")
    result.save(work / "spritesheet.png")
    report.update(budget=run.budget.summary(), seconds=round(time.monotonic() - started, 1))
    return result, report


# ── the hatch ───────────────────────────────────────────────────────────

class _Run:
    def __init__(self, sprite, budget: Budget, work: Path) -> None:
        self.sprite, self.budget, self.work = sprite, budget, work
        self.provider = sprite.provider

    def draw(self, what: str, prompt: str, *, references: list[Path], aspect: tuple[str, str | None],
             quality: str) -> Path | None:
        """One image call, priced and checked first; the image moved into the
        work directory. None when nothing usable came back."""
        from agent.pet.generate import imagegen

        semantic, exact = aspect
        raw = estimate(semantic, quality, len(references))
        price = self.budget.price(semantic, quality, len(references))
        self.budget.check(what, price)
        refs = [str(p) for p in references]
        kwargs = {"aspect_ratio": semantic, "quality": quality, "reference_images": refs,
                  "reference_image_urls": refs}
        if exact:
            kwargs["aspect_ratio_exact"] = exact
        t0 = time.monotonic()
        try:
            result = self.provider.generate(prompt, **kwargs)
        except Exception as error:
            result = {"success": False, "error": str(error), "error_type": "crash"}
        self.budget.charge(what, raw, price, result)
        logger.info("app_topic: pet %s: %s in %.0fs (spent $%.2f)", what,
                    "drawn" if result.get("success") else f"failed ({result.get('error')})",
                    time.monotonic() - t0, self.budget.spent)
        if not result.get("success") or not result.get("image"):
            return None
        try:
            local = imagegen._save_local(str(result["image"]), prefix=f"pet_{what}")
            target = self.work / f"{what}{local.suffix or '.png'}"
            shutil.move(str(local), target)
            return target
        except Exception:
            logger.warning("app_topic: pet %s: could not keep the image", what, exc_info=True)
            return None


def hatch(prompt: str, *, sprite, work: Path, max_cost: float = DEFAULT_MAX_COST,
          max_repairs: int = MAX_ROW_REPAIRS, style: str = "auto", sheet_quality: str = SHEET_QUALITY):
    """Draw, slice, repair and validate a pet; returns ``(atlas, report)``.
    Raises ProviderRefused at the first account-level refusal, HatchFailed
    otherwise, both carrying the report. Writes the sheet, the guide, any
    redrawn rows, the atlas and its contact sheet into *work*."""
    from agent.pet.generate import atlas, prompts

    work.mkdir(parents=True, exist_ok=True)
    guarded = sprite.provider if isinstance(sprite.provider, StopOnRefusal) else StopOnRefusal(sprite.provider)
    run = _Run(type(sprite)(name=sprite.name, provider=guarded, supports_references=sprite.supports_references),
               Budget(max_cost), work)
    report: dict = {"path": "one-sheet", "repaired_rows": [], "mirrored_left": False, "row_errors": {}}
    started = time.monotonic()

    def finish(error: Exception | None = None) -> dict:
        report.update(budget=run.budget.summary(), seconds=round(time.monotonic() - started, 1))
        (work / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
        return report

    def fail(message: str):
        report["error"] = message
        finish()
        if guarded.refused:
            raise ProviderRefused(plain_refusal(sprite.name, guarded.refused), report)
        raise HatchFailed(message, report)

    guide = work / "guide.png"
    layout_guide().save(guide)
    try:
        sheet = run.draw("sheet", sheet_prompt(prompt, style), references=[guide], aspect=SHEET_ASPECT,
                         quality=sheet_quality)
    except OverBudget as error:
        fail(f"the sheet alone is over budget: {error}")
    if sheet is None:
        fail("the image provider returned no sheet")

    frames, errors = slice_sheet(sheet)
    report["row_errors"] = dict(errors)
    if "idle" not in frames:
        fail(f"the sheet is unusable: its idle row could not be read ({errors.get('idle')})")

    def settle_left() -> None:
        right, left = frames.get("running-right"), frames.get("running-left")
        if right and (not left or faces_wrong_way(left, right)):
            if left:
                report["row_errors"]["running-left"] = "faces right"
            frames["running-left"] = atlas.mirror_frames(right)
            errors.pop("running-left", None)
            report["mirrored_left"] = True

    settle_left()
    idle_ref = idle_reference(frames["idle"][0], work)

    repaired: list[str] = report["repaired_rows"]
    while True:
        bad = [s for s, _r, _c in atlas.ROW_SPECS if s in errors]
        named = {}
        if not bad:
            result, validation, named = compose(frames)
            report["validation"] = validation
            bad = [s for s, _r, _c in atlas.ROW_SPECS if s in named]
            for state in bad:
                errors[state] = named[state]
                report["row_errors"].setdefault(state, named[state])
                frames.pop(state, None)
            if not bad:
                if not validation["ok"]:
                    fail("; ".join(validation["errors"]) or "atlas validation failed")
                break
        # running-left costs nothing when running-right is sound (and was not mirrored already).
        if ("running-left" in bad and "running-right" not in bad and frames.get("running-right")
                and not report["mirrored_left"]):
            frames.pop("running-left", None)
            settle_left()
            continue
        # A redrawn running-right brings its mirror: running-left waits for it.
        state = next((s for s in bad if s != "running-left" or "running-right" not in bad), bad[0])
        if state in repaired:
            fail(f"the {state} row is still unusable after it was redrawn: {errors[state]}")
        if len(repaired) >= max_repairs:
            fail(f"{len(bad)} more rows are unusable ({', '.join(bad)}) after {len(repaired)} redrawn: "
                 "more than this hatch redraws")
        count = dict((s, c) for s, _r, c in atlas.ROW_SPECS)[state]
        repaired.append(state)
        report["path"] = "one-sheet + rows"
        try:
            strip = run.draw(f"row-{state}", row_prompt(state, count, prompt, style),
                             references=[idle_ref], aspect=("landscape", None), quality=ROW_QUALITY)
        except OverBudget as error:
            fail(f"the {state} row could not be redrawn within the budget: {error}")
        if strip is None:
            fail(f"the {state} row could not be redrawn: the provider returned no image")
        try:
            frames[state] = atlas.extract_strip_frames(strip, count, method="auto", fit=False)
            errors.pop(state, None)
        except Exception as error:
            errors[state] = f"redrawn: {error}"
        if state == "running-right":
            frames.pop("running-left", None)
            errors.pop("running-left", None)
            settle_left()

    report["filled_states"] = validation["filled_states"]
    result.save(work / "spritesheet.png")
    contact_sheet(result).save(work / "contact-sheet.png")
    finish()
    return result, report
