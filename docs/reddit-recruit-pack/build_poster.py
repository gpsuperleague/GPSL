"""
GPSL recruit poster — classy hero + editorial copy + custom art strip at bottom.
No website screenshots. Art stays below the text, not under it.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageEnhance

ROOT = Path(__file__).resolve().parents[2]
PACK = Path(__file__).resolve().parent
ART = PACK / "art"
OUT_PNG = PACK / "00-recruit-poster.png"
OUT_JPG = PACK / "00-recruit-poster.jpg"
LOGO = ROOT / "images" / "League" / "Logos" / "GPSL_logo.png"
STADIUM = Path(
    r"C:\Users\Rotav\.cursor\projects\d-GPSL-Cursor\assets\gpsl-stadium-hero-clean.jpg"
)
STADIUM_FALLBACK = ROOT / "images" / "stadiums" / "BAR.jpg"

W, H = 1080, 1440
ORANGE = (255, 153, 0)
WHITE = (246, 246, 246)
SILVER = (196, 196, 196)
MUTED = (168, 168, 168)
DIM = (110, 110, 110)
RULE = (48, 48, 48)
BG = (5, 5, 5)

ART_TILES = [
    (ART / "matchday.jpg", "MATCH DAY"),
    (ART / "transfers.jpg", "TRANSFERS"),
    (ART / "finances.jpg", "FINANCES"),
    (ART / "platform.jpg", "THE SITE"),
]


def font(path: str, size: int) -> ImageFont.ImageFont:
    try:
        return ImageFont.truetype(path, size)
    except Exception:
        return ImageFont.load_default()


def cover(src: Image.Image, tw: int, th: int, bias_y: float = 0.35) -> Image.Image:
    sw, sh = src.size
    scale = max(tw / sw, th / sh)
    nw, nh = int(sw * scale), int(sh * scale)
    im = src.resize((nw, nh), Image.Resampling.LANCZOS)
    left = (nw - tw) // 2
    top = int(max(0, (nh - th) * bias_y))
    return im.crop((left, top, left + tw, top + th))


def hero_band(height: int) -> Image.Image:
    src = STADIUM if STADIUM.exists() else STADIUM_FALLBACK
    cut = cover(Image.open(src).convert("RGB"), W, height, bias_y=0.35)
    cut = ImageEnhance.Brightness(cut).enhance(0.75 if STADIUM.exists() else 0.48)
    cut = ImageEnhance.Contrast(cut).enhance(1.1)
    grade = Image.new("RGB", cut.size, (12, 6, 0))
    cut = Image.blend(cut, grade, 0.18)
    fade = Image.new("L", (W, height), 0)
    fd = ImageDraw.Draw(fade)
    for y in range(height):
        t = y / max(height - 1, 1)
        if t < 0.58:
            a = 255
        else:
            fade_t = max(0.0, min(1.0, (t - 0.58) / 0.42))
            a = int(255 * ((1.0 - fade_t) ** 1.1))
        fd.line([(0, y), (W, y)], fill=max(0, min(255, a)))
    return Image.composite(cut, Image.new("RGB", (W, height), BG), fade)


def style_tile(path: Path, tw: int, th: int) -> Image.Image:
    im = cover(Image.open(path).convert("RGB"), tw, th, bias_y=0.4)
    im = ImageEnhance.Brightness(im).enhance(0.72)
    im = ImageEnhance.Color(im).enhance(0.85)
    im = ImageEnhance.Contrast(im).enhance(1.08)
    # dark vignette
    vig = Image.new("L", (tw, th), 0)
    vd = ImageDraw.Draw(vig)
    for y in range(th):
        for x in range(0, tw, 4):
            pass
    # edge darken via radial-ish gradient
    overlay = Image.new("RGBA", (tw, th), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    od.rectangle([0, 0, tw, th], fill=(0, 0, 0, 40))
    # bottom gradient for label
    for i in range(56):
        a = int(170 * (i / 55))
        od.line([(0, th - 1 - i), (tw, th - 1 - i)], fill=(0, 0, 0, a))
    out = im.convert("RGBA")
    out = Image.alpha_composite(out, overlay)
    return out


def build_art_strip(width: int, height: int) -> Image.Image:
    """2×2 classy custom art montage for the bottom section only."""
    gap = 10
    pad = 56
    inner_w = width - pad * 2
    inner_h = height - 8
    tile_w = (inner_w - gap) // 2
    tile_h = (inner_h - gap) // 2
    canvas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    f_lab = font(r"C:\Windows\Fonts\seguisb.ttf", 13)

    for i, (path, label) in enumerate(ART_TILES):
        if not path.exists():
            continue
        r, c = divmod(i, 2)
        x = pad + c * (tile_w + gap)
        y = r * (tile_h + gap)
        tile = style_tile(path, tile_w, tile_h)
        # thin frame
        framed = Image.new("RGBA", (tile_w, tile_h), (0, 0, 0, 0))
        framed.alpha_composite(tile)
        fd = ImageDraw.Draw(framed)
        fd.rectangle([0, 0, tile_w - 1, tile_h - 1], outline=(70, 55, 30, 160), width=1)
        # label
        tw = draw.textbbox((0, 0), label, font=f_lab)
        # use framed draw
        fd.text((14, tile_h - 28), label, font=f_lab, fill=(255, 153, 0, 230))
        canvas.alpha_composite(framed, (x, y))

    return canvas


def main() -> None:
    img = Image.new("RGB", (W, H), BG)
    hero_h = 480
    img.paste(hero_band(hero_h), (0, 0))
    draw = ImageDraw.Draw(img)

    f_eye = font(r"C:\Windows\Fonts\seguisb.ttf", 15)
    f_h1 = font(r"C:\Windows\Fonts\georgia.ttf", 74)
    f_sub = font(r"C:\Windows\Fonts\georgiai.ttf", 26)
    f_lab = font(r"C:\Windows\Fonts\seguisb.ttf", 14)
    f_body = font(r"C:\Windows\Fonts\segoeui.ttf", 17)
    f_foot = font(r"C:\Windows\Fonts\segoeui.ttf", 14)
    f_tag = font(r"C:\Windows\Fonts\georgiai.ttf", 18)

    def size(text, fnt):
        b = draw.textbbox((0, 0), text, font=fnt)
        return b[2] - b[0], b[3] - b[1]

    def center(text, y, fnt, fill):
        tw, th = size(text, fnt)
        draw.text(((W - tw) / 2, y), text, font=fnt, fill=fill)
        return th

    # logo
    logo = Image.open(LOGO).convert("RGBA")
    lw = 280
    lh = int(logo.height * (lw / logo.width))
    logo = logo.resize((lw, lh), Image.Resampling.LANCZOS)
    plate = Image.new("RGBA", (lw + 80, lh + 50), (0, 0, 0, 0))
    pd = ImageDraw.Draw(plate)
    pd.ellipse([0, 10, lw + 80, lh + 40], fill=(0, 0, 0, 150))
    plate = plate.filter(ImageFilter.GaussianBlur(16))
    layer = img.convert("RGBA")
    lx = (W - lw) // 2
    ly = 48
    layer.alpha_composite(plate, (lx - 40, ly - 12))
    layer.alpha_composite(logo, (lx, ly))
    img = layer.convert("RGB")
    draw = ImageDraw.Draw(img)

    y = ly + lh + 28
    center("GP SUPER LEAGUE", y, f_eye, SILVER)
    y += 32

    line = "Own the club."
    tw, _ = size(line, f_h1)
    x = (W - tw) / 2
    draw.text((x + 2, y + 3), line, font=f_h1, fill=(0, 0, 0))
    draw.text((x, y), line, font=f_h1, fill=WHITE)
    y += 86
    center("Run everything that matters.", y, f_sub, ORANGE)
    y += 44
    draw.line([W // 2 - 26, y, W // 2 + 26, y], fill=ORANGE, width=2)
    y += 28

    bands = [
        (
            "MATCH DAY",
            "Propose kick-offs, check in, submit the score — the fixture lives on your club site.",
        ),
        (
            "TRANSFER CENTRE",
            "Owner deals, player drafts, special auctions, club & manager auctions, renewals.",
        ),
        (
            "FINANCES",
            "Wages, credit, ledgers, budgets and FFP pressure. Every signing hits the books.",
        ),
        (
            "BESPOKE WEBSITE",
            "Built specifically for GPSL — not a shared multi-league template. Deeper because it’s ours.",
        ),
        (
            "TRUE COMPETITION",
            "GP-only · unique assets · PA3 · 60-club pyramid with promotion & relegation.",
        ),
    ]

    left = 72
    label_w = 200
    text_x = left + label_w + 20
    text_w = W - text_x - 72

    for i, (label, body) in enumerate(bands):
        if i:
            draw.line([left, y, W - left, y], fill=RULE, width=1)
            y += 16
        draw.text((left, y + 1), label, font=f_lab, fill=ORANGE)
        words = body.split()
        lines, cur = [], ""
        for w in words:
            trial = w if not cur else f"{cur} {w}"
            if size(trial, f_body)[0] <= text_w:
                cur = trial
            else:
                lines.append(cur)
                cur = w
        if cur:
            lines.append(cur)
        by = y
        for ln in lines:
            draw.text((text_x, by), ln, font=f_body, fill=MUTED)
            by += size(ln, f_body)[1] + 4
        y = max(y + 24, by) + 12

    # --- custom art strip BELOW the text (not underneath it) ---
    y += 8
    draw.line([left, y, W - left, y], fill=RULE, width=1)
    y += 18
    center("LIFE AS A GPSL OWNER", y, f_eye, DIM)
    y += 28

    footer_reserve = 110
    art_h = max(280, H - y - footer_reserve)
    strip = build_art_strip(W, art_h)
    layer = img.convert("RGBA")
    layer.alpha_composite(strip, (0, y))
    img = layer.convert("RGB")
    draw = ImageDraw.Draw(img)
    y += art_h + 16

    y = min(y, H - 95)
    center(
        "Waiting list open  ·  Discord  ·  PC & Console  ·  GP-only  ·  PA3",
        y,
        f_foot,
        DIM,
    )
    y += 30
    center("More than just a match.", y, f_tag, (128, 128, 128))

    draw.rectangle([22, 22, W - 22, H - 22], outline=(34, 34, 34), width=1)

    img.save(OUT_PNG)
    img.save(OUT_JPG, quality=94)
    print(f"saved {OUT_PNG} {img.size}")


if __name__ == "__main__":
    main()
