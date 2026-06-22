#!/usr/bin/env python3
"""Generate dashboard tile watermark PNGs (transparent, light icon on dark)."""
from __future__ import annotations

import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "images" / "dashboard_tiles"
MANIFEST = ROOT / "dashboard_tiles_manifest.json"

SIZE = 512
ACCENT = (255, 153, 0, 255)
ICON = (255, 255, 255, 210)
GLOW = (255, 153, 0, 45)


def load_panels():
    if MANIFEST.exists():
        return json.loads(MANIFEST.read_text(encoding="utf-8"))
    raise SystemExit(f"Missing {MANIFEST}")


def font(size: int):
    for name in ("segoeui.ttf", "arial.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def draw_icon(draw: ImageDraw.ImageDraw, kind: str, cx: int, cy: int, r: int):
    k = (kind or "default").lower()
    if k in ("squad", "gpdb", "player"):
        draw.ellipse((cx - r // 2, cy - r, cx + r // 2, cy - r // 3), outline=ICON, width=6)
        draw.arc((cx - r, cy - r // 2, cx + r, cy + r), 200, 340, fill=ICON, width=6)
    elif k in ("finances", "bank", "central"):
        draw.rectangle((cx - r, cy - r // 2, cx + r, cy + r // 2), outline=ICON, width=6)
        draw.text((cx - r // 3, cy - r // 4), "B", fill=ICON, font=font(r))
    elif k in ("fixtures", "matchday", "cup"):
        draw.ellipse((cx - r, cy - r, cx + r, cy + r), outline=ICON, width=6)
        draw.line((cx - r, cy, cx + r, cy), fill=ICON, width=4)
        draw.line((cx, cy - r, cx, cy + r), fill=ICON, width=4)
    elif k in ("transfer", "market", "auction"):
        draw.polygon(
            [(cx, cy - r), (cx + r, cy + r // 3), (cx - r, cy + r // 3)],
            outline=ICON,
            width=6,
        )
    elif k in ("stadium", "club"):
        draw.polygon(
            [(cx - r, cy + r // 2), (cx, cy - r), (cx + r, cy + r // 2)],
            outline=ICON,
            width=6,
        )
        draw.rectangle((cx - r // 2, cy, cx + r // 2, cy + r // 2), outline=ICON, width=5)
    elif k in ("nation", "world"):
        draw.ellipse((cx - r, cy - r, cx + r, cy + r), outline=ICON, width=6)
        draw.arc((cx - r, cy - r // 2, cx + r, cy + r), 0, 180, fill=ICON, width=4)
    elif k in ("admin", "inbox", "learning"):
        draw.rounded_rectangle(
            (cx - r, cy - r // 2, cx + r, cy + r // 2), radius=18, outline=ICON, width=6
        )
    else:
        draw.ellipse((cx - r, cy - r, cx + r, cy + r), outline=ICON, width=6)
        draw.line((cx - r // 2, cy, cx + r // 2, cy), fill=ICON, width=5)
        draw.line((cx, cy - r // 2, cx, cy + r // 2), fill=ICON, width=5)


def render_tile(panel: dict) -> Image.Image:
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    cx, cy = SIZE // 2, SIZE // 2 - 20
    r = 150
    glow_r = int(r * 1.35)
    draw.ellipse(
        (cx - glow_r, cy - glow_r, cx + glow_r, cy + glow_r),
        fill=GLOW,
    )
    draw_icon(draw, panel.get("icon", panel.get("id", "default")), cx, cy, r)
    label = (panel.get("short") or panel.get("label") or panel.get("id", ""))[:14]
    f = font(36)
    tw = draw.textlength(label, font=f)
    draw.text((cx - tw / 2, cy + r + 24), label, fill=(255, 255, 255, 170), font=f)
    return img


def main():
    panels = load_panels()
    OUT.mkdir(parents=True, exist_ok=True)
    for panel in panels:
        pid = panel["id"]
        out = OUT / f"{pid}.png"
        render_tile(panel).save(out, "PNG")
        print(f"wrote {out.relative_to(ROOT)}")
    print(f"Done - {len(panels)} tiles")


if __name__ == "__main__":
    main()
