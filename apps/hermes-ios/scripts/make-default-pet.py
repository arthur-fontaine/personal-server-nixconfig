#!/usr/bin/env python3
"""Draws the default pet, "Pip", the app ships with until the server builds it with
Hermes' own pet: a Codex pet package (pet.json + spritesheet.webp, 8 columns x 9 rows
of 192x208 cells, rows idle, running-right, running-left, waving, jumping, failed,
waiting, running, review) and the 1024x1024 app icon.

Pixel art on a 48x52 grid, scaled 4x with nearest-neighbour. Needs Pillow.
Usage: make-default-pet.py <out-pet-dir> <out-icon.png>
"""
import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw

W, H, SCALE = 48, 52, 4
ROWS = [("idle", 6), ("running-right", 8), ("running-left", 8), ("waving", 4), ("jumping", 5),
        ("failed", 8), ("waiting", 6), ("running", 6), ("review", 6)]

OUTLINE = (58, 36, 22, 255)
BODY = (242, 164, 58, 255)
BODY_LIGHT = (255, 205, 120, 255)
BODY_DARK = (205, 120, 40, 255)
BELLY = (255, 236, 196, 255)
WING = (255, 255, 255, 255)
WING_SHADE = (214, 226, 240, 255)
EYE = (40, 28, 24, 255)
CHEEK = (255, 128, 120, 255)
HELMET = (150, 160, 178, 255)
HELMET_LIGHT = (205, 214, 228, 255)
BLUE = (90, 150, 230, 255)


def ellipse(d, box, fill, outline=OUTLINE):
    d.ellipse(box, fill=fill, outline=outline)


def draw_pet(dx=0, dy=0, squash=0, wing_l=0, wing_r=0, eyes="open", mouth="smile", look=0,
             tilt_cheek=True, droop=False, sweat=False, mark=None, dim=False):
    """One 48x52 frame. wing_*: -1 down, 0 rest, 1 up, 2 high. look: eye x offset."""
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx, top = 24 + dx, 12 + dy
    bw, bh = 12 + squash, 15 - squash  # half width, half height of the round body
    by = top + 20

    def wing(side, pose):
        sx = cx + side * (bw - 1)
        lift = {-1: 4, 0: 0, 1: -5, 2: -9}[pose]
        pts = [(sx, by - 2), (sx + side * 8, by - 5 + lift), (sx + side * 10, by - 1 + lift),
               (sx + side * 7, by + 3 + lift // 2), (sx + side * 1, by + 5)]
        d.polygon(pts, fill=WING, outline=OUTLINE)
        d.line([(sx + side * 3, by + 1 + lift // 3), (sx + side * 7, by - 2 + lift)], fill=WING_SHADE)

    wing(-1, wing_l)
    wing(1, wing_r)
    # feet
    for fx in (-5, 3):
        d.rectangle([cx + fx, by + bh - 2, cx + fx + 3, by + bh + 1], fill=BODY_DARK, outline=OUTLINE)
    # body
    ellipse(d, [cx - bw, by - bh, cx + bw, by + bh], BODY)
    d.ellipse([cx - bw + 3, by - bh + 2, cx - bw + 9, by - bh + 7], fill=BODY_LIGHT)
    ellipse(d, [cx - 7, by + 1, cx + 7, by + bh - 2], BELLY, outline=None)
    # winged helmet (Hermes' petasos)
    hy = by - bh - 1 + (2 if droop else 0)
    d.pieslice([cx - 10, hy - 3, cx + 10, hy + 13], 180, 360, fill=HELMET, outline=OUTLINE)
    d.line([(cx - 7, hy + 1), (cx - 2, hy - 1)], fill=HELMET_LIGHT, width=1)
    for side in (-1, 1):
        hx = cx + side * 9
        d.polygon([(hx, hy + 3), (hx + side * 7, hy - 3), (hx + side * 6, hy + 1), (hx + side * 8, hy + 2), (hx + side * 2, hy + 6)],
                  fill=WING, outline=OUTLINE)
    # face
    ey = by - 4 + (2 if droop else 0)
    for side in (-1, 1):
        ex = cx + side * 5 + look
        if eyes == "open":
            d.rectangle([ex - 1, ey - 2, ex + 1, ey + 2], fill=EYE)
            d.point((ex, ey - 1), fill=(255, 255, 255, 255))
        elif eyes == "closed":
            d.line([(ex - 2, ey + 1), (ex + 2, ey + 1)], fill=EYE)
        elif eyes == "happy":
            d.line([(ex - 2, ey + 1), (ex, ey - 1), (ex + 2, ey + 1)], fill=EYE)
        elif eyes == "x":
            d.line([(ex - 2, ey - 2), (ex + 2, ey + 2)], fill=EYE)
            d.line([(ex - 2, ey + 2), (ex + 2, ey - 2)], fill=EYE)
        elif eyes == "up":
            d.rectangle([ex - 1, ey - 3, ex + 1, ey], fill=EYE)
        if tilt_cheek:
            d.rectangle([cx + side * 8 - 1, ey + 3, cx + side * 8 + 1, ey + 4], fill=CHEEK)
    my = ey + 5
    if mouth == "smile":
        d.line([(cx - 2, my), (cx, my + 1), (cx + 2, my)], fill=EYE)
    elif mouth == "open":
        d.ellipse([cx - 2, my - 1, cx + 2, my + 3], fill=EYE)
    elif mouth == "flat":
        d.line([(cx - 2, my + 1), (cx + 2, my + 1)], fill=EYE)
    elif mouth == "sad":
        d.line([(cx - 2, my + 1), (cx, my), (cx + 2, my + 1)], fill=EYE)
    if sweat:
        d.polygon([(cx + bw - 1, ey - 6), (cx + bw + 1, ey - 2), (cx + bw - 3, ey - 2)], fill=BLUE, outline=OUTLINE)
    if mark == "?":
        mx, my2 = cx + bw + 3, by - bh - 4
        d.arc([mx - 3, my2 - 4, mx + 3, my2 + 2], 180, 90, fill=OUTLINE, width=2)
        d.line([(mx, my2 + 2), (mx, my2 + 4)], fill=OUTLINE, width=2)
        d.point((mx, my2 + 7), fill=OUTLINE)
    elif mark == "dots":
        for i in range(3):
            d.rectangle([cx + bw - 2 + i * 4, by - bh - 4, cx + bw - 1 + i * 4, by - bh - 3], fill=OUTLINE)
    elif mark == "spark":
        sx, sy = cx - bw - 4, by - bh
        d.line([(sx, sy - 3), (sx, sy + 3)], fill=(255, 210, 80, 255))
        d.line([(sx - 3, sy), (sx + 3, sy)], fill=(255, 210, 80, 255))
    if dim:
        px = img.load()
        for y in range(H):
            for x in range(W):
                r, g, b, a = px[x, y]
                if a:
                    px[x, y] = (int(r * 0.8), int(g * 0.8), int(b * 0.85), a)
    return img


def frames():
    rows = {}
    rows["idle"] = [draw_pet(dy=b, eyes=e) for b, e in
                    [(0, "open"), (0, "open"), (1, "open"), (1, "closed"), (0, "open"), (0, "open")]]
    run = []
    for i in range(8):
        phase = i / 8 * 2 * math.pi
        run.append(draw_pet(dx=1, dy=-abs(round(2 * math.sin(phase))), wing_l=1 if i % 2 else 0, wing_r=0 if i % 2 else 1,
                            look=1, mouth="open" if i % 4 == 0 else "smile"))
    rows["running-right"] = run
    rows["running-left"] = [f.transpose(Image.FLIP_LEFT_RIGHT) for f in run]
    rows["waving"] = [draw_pet(wing_r=w, eyes="happy", mouth="open") for w in (1, 2, 1, 2)]
    rows["jumping"] = [draw_pet(dy=2, squash=2, eyes="closed"), draw_pet(dy=-4, wing_l=1, wing_r=1, mouth="open"),
                       draw_pet(dy=-9, wing_l=2, wing_r=2, eyes="happy", mouth="open", mark="spark"),
                       draw_pet(dy=-4, wing_l=1, wing_r=1, eyes="happy"), draw_pet(dy=1, squash=1)]
    rows["failed"] = [draw_pet(dy=1 + (i % 2), wing_l=-1, wing_r=-1, eyes="x" if i in (2, 3, 4) else "closed",
                               mouth="sad", droop=True, sweat=i >= 2, dim=True, tilt_cheek=False) for i in range(8)]
    rows["waiting"] = [draw_pet(look=l, mark="?" if i >= 2 else None, eyes="closed" if i == 4 else "open", mouth="flat")
                       for i, l in enumerate([0, -1, -1, 0, 1, 1])]
    rows["running"] = [draw_pet(dy=-(i % 2), wing_l=(i % 3) - 1 if i % 3 else 1, wing_r=1 - (i % 3), mark="dots" if i % 2 else None,
                                eyes="open", mouth="flat", look=(i % 2)) for i in range(6)]
    rows["review"] = [draw_pet(eyes="up", look=l, mouth="flat", mark="dots" if i % 3 == 2 else None)
                      for i, l in enumerate([-1, -1, 0, 1, 1, 0])]
    return rows


def main(out_dir: Path, icon_path: Path):
    rows = frames()
    sheet = Image.new("RGBA", (192 * 8, 208 * 9), (0, 0, 0, 0))
    for r, (name, count) in enumerate(ROWS):
        cells = rows[name]
        assert len(cells) == count, (name, len(cells))
        for c, cell in enumerate(cells):
            sheet.alpha_composite(cell.resize((W * SCALE, H * SCALE), Image.NEAREST), (c * 192, r * 208))
    out_dir.mkdir(parents=True, exist_ok=True)
    sheet.save(out_dir / "spritesheet.webp", "WEBP", lossless=True, quality=100)
    (out_dir / "pet.json").write_text(json.dumps({
        "id": "pip", "displayName": "Pip", "name": "Pip",
        "description": "A small winged messenger, Hermes' default companion.",
        "spritesheetPath": "spritesheet.webp", "version": 0,
    }, indent=2) + "\n")
    # Icon: the first idle frame on the accent colour, as the backend renders Hermes' pets.
    icon = Image.new("RGBA", (1024, 1024), (255, 214, 140, 255))
    glow = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([152, 172, 872, 892], fill=(255, 236, 200, 255))
    icon.alpha_composite(glow)
    pet = rows["idle"][0].crop((2, 4, 46, 52)).resize((44 * 16, 48 * 16), Image.NEAREST)
    icon.alpha_composite(pet, ((1024 - pet.width) // 2, (1024 - pet.height) // 2 + 30))
    icon.convert("RGB").save(icon_path)


if __name__ == "__main__":
    main(Path(sys.argv[1]), Path(sys.argv[2]))
