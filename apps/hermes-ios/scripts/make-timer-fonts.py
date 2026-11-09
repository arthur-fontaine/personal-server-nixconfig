#!/usr/bin/env python3
"""Draws the fonts that animate the Live Activity (Shared/TimerAnimation.swift). A Live Activity
redraws only timers, so a timer's seconds digit, drawn in a bitmap (sbix) font whose digits are
images, steps through them once a second.

- HermesPet-<row>.ttf, from the pet's sheet: each row, frame d % count on digit d. In the
  extension's bundle: the system draws the Live Activity, and it reads fonts from the bundle only
  (one made by the app in the app group blanked the whole activity on the device).
- HermesMaskEven.ttf / HermesMaskOdd.ttf: an opaque square on even / odd digits, nothing on the
  others. Two timers a fraction of a second apart, one in each, are opaque together only in that
  fraction (every other second): masks for animations faster than one image a second.

Glyph order (FrameFont relies on it): .notdef, space, colon, d0-d9. Needs fontTools and Pillow.
Usage: make-timer-fonts.py <out-dir> <spritesheet>
"""
import io
import sys
from pathlib import Path

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import newTable
from fontTools.ttLib.tables.sbixGlyph import Glyph
from fontTools.ttLib.tables.sbixStrike import Strike
from PIL import Image

PX = 96  # the strike's ppem: the Live Activity's still size (Metric.activityStillPixels)


def png(image: Image.Image) -> bytes:
    out = io.BytesIO()
    image.save(out, format="PNG")
    return out.getvalue()


def build(name: str, images: list, path: Path) -> None:
    digits = [f"d{i}" for i in range(10)]
    order = [".notdef", "space", "colon"] + digits
    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap({ord(" "): "space", ord(":"): "colon"} | {ord(str(i)): f"d{i}" for i in range(10)})
    empty = TTGlyphPen(None).glyph()
    fb.setupGlyf({g: empty for g in order})
    fb.setupHorizontalMetrics({g: (1000, 0) for g in order})
    fb.setupHorizontalHeader(ascent=1000, descent=0)
    fb.setupNameTable({"familyName": name, "styleName": "Regular", "psName": name})
    fb.setupOS2(sTypoAscender=1000, sTypoDescender=0, usWinAscent=1000, usWinDescent=0)
    fb.setupPost()
    sbix = newTable("sbix")
    sbix.version, sbix.flags, sbix.strikes = 1, 1, {}
    strike = Strike(ppem=PX, resolution=72)
    for i, g in enumerate(digits):
        strike.glyphs[g] = Glyph(glyphName=g, graphicType="png ", imageData=png(images[i]), originOffsetX=0,
                                 originOffsetY=0)
    sbix.strikes[PX] = strike
    fb.font["sbix"] = sbix
    fb.save(path)


out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
ROWS = [("idle", 6), ("running-right", 8), ("running-left", 8), ("waving", 4), ("jumping", 5), ("failed", 8),
        ("waiting", 6), ("running", 6), ("review", 6)]
sheet = Image.open(sys.argv[2]).convert("RGBA")
cw, ch = sheet.width // 8, sheet.height // 9
cells = {r: [sheet.crop((c * cw, i * ch, (c + 1) * cw, (i + 1) * ch)) for c in range(n)] for i, (r, n) in enumerate(ROWS)}
# One box over every frame of every row: the pet keeps its size and place from row to row.
boxes = [f.getbbox() for fs in cells.values() for f in fs if f.getbbox()]
box = (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))
side = max(box[2] - box[0], box[3] - box[1])
for row, frames in cells.items():
    images = []
    for f in frames:
        f = f.crop(box)
        f = f.resize((max(1, round(f.width * PX / side)), max(1, round(f.height * PX / side))), Image.NEAREST)
        canvas = Image.new("RGBA", (PX, PX), (0, 0, 0, 0))
        canvas.alpha_composite(f, ((PX - f.width) // 2, PX - f.height))
        images.append(canvas)
    build(f"HermesPet-{row}", [images[d % len(images)] for d in range(10)], out / f"HermesPet-{row}.ttf")
square = Image.new("RGBA", (PX, PX), (0, 0, 0, 255))
clear = Image.new("RGBA", (PX, PX), (0, 0, 0, 0))
build("HermesMaskEven", [square if d % 2 == 0 else clear for d in range(10)], out / "HermesMaskEven.ttf")
build("HermesMaskOdd", [square if d % 2 == 1 else clear for d in range(10)], out / "HermesMaskOdd.ttf")
