"""
GPSL recruit poster — cinematic hero + dark translucent site montage + editorial bands.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageEnhance

ROOT = Path(__file__).resolve().parents[2]
PACK = Path(__file__).resolve().parent
OUT_PNG = PACK / "00-recruit-poster.png"
OUT_JPG = PACK / "00-recruit-poster.jpg"
LOGO = ROOT / "images" / "League" / "Logos" / "GPSL_logo.png"
AI_BASE = Path(
    r"C:\Users\Rotav\.cursor\projects\d-GPSL-Cursor\assets\gpsl-stadium-hero-clean.jpg"
)
STADIUM_FALLBACK = ROOT / "images" / "stadiums" / "BAR.jpg"
BADGE_DIR = ROOT / "images" / "club_badges"

SHOTS = [
    PACK / "02-site-matchday.png",
    PACK / "04-site-finances.png",
    PACK / "01-site-fixtures.png",
    PACK / "05-site-tables.png",
    PACK / "03-site-schedule.png",
]

W, H = 1080, 1440
ORANGE = (255, 153, 0)
WHITE = (246, 246, 246)
SILVER = (196, 196, 196)
MUTED = (175, 175, 175)
DIM = (110, 110, 110)
RULE = (55, 55, 55)
BG = (5, 5, 5)


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


def hero_from_ai_or_stadium() -> Image.Image:
    hero_h = 620
    src = AI_BASE if AI_BASE.exists() else STADIUM_FALLBACK
    cut = cover(Image.open(src).convert("RGB"), W, hero_h, bias_y=0.35)
    cut = ImageEnhance.Brightness(cut).enhance(0.78 if AI_BASE.exists() else 0.48)
    cut = ImageEnhance.Contrast(cut).enhance(1.12)
    cut = ImageEnhance.Color(cut).enhance(0.9)
    grade = Image.new("RGB", cut.size, (12, 6, 0))
    cut = Image.blend(cut, grade, 0.16)

    fade = Image.new("L", (W, hero_h), 0)
    fd = ImageDraw.Draw(fade)
    for y in range(hero_h):
        t = y / (hero_h - 1)
        a = 255 if t < 0.55 else int(255 * (1 - (t - 0.55) / 0.45) ** 1.1)
        fd.line([(0, y), (W, y)], fill=max(0, min(255, a)))
    return Image.composite(cut, Image.new("RGB", (W, hero_h), BG), fade)


def dark_panel(src: Path, tw: int, th: int) -> Image.Image:
    im = cover(Image.open(src).convert("RGB"), tw, th, bias_y=0.0)
    im = ImageEnhance.Brightness(im).enhance(0.42)
    im = ImageEnhance.Contrast(im).enhance(1.08)
    im = ImageEnhance.Color(im).enhance(0.5)
    # charcoal wash — keep darker / classier
    wash = Image.new("RGB", im.size, (8, 8, 8))
    im = Image.blend(im, wash, 0.38)
    return im.convert("RGBA")


def build_lower_montage(top: int, bottom: int) -> Image.Image:
    """Translucent overlapping site panels + faint crests for the lower half."""
    h = bottom - top
    canvas = Image.new("RGBA", (W, h), (0, 0, 0, 0))

    # Placement: staggered overlapping frames (classy collage, not a grid)
    layout = [
        # path, x, y, w, h, rotate, alpha (0–255 panel opacity)
        (SHOTS[0], -40, 10, 580, 310, -3.2, 155),   # Match Day
        (SHOTS[1], 460, 30, 660, 290, 2.6, 145),    # Finances
        (SHOTS[2], 20, 240, 540, 270, 2.0, 140),    # Fixtures
        (SHOTS[3], 500, 270, 600, 260, -2.0, 140),  # Tables
        (SHOTS[4], 160, 420, 720, 230, 1.1, 125),   # Schedule
    ]

    for path, x, y, tw, th, rot, alpha in layout:
        if not path.exists():
            continue
        panel = dark_panel(path, tw, th)
        # subtle border
        bd = ImageDraw.Draw(panel)
        bd.rectangle([0, 0, tw - 1, th - 1], outline=(70, 70, 70, 90), width=1)
        panel = panel.rotate(rot, resample=Image.Resampling.BICUBIC, expand=True)
        # apply overall alpha
        a = panel.split()[-1].point(lambda p: int(p * alpha / 255))
        panel.putalpha(a)
        canvas.alpha_composite(panel, (x, y))

    # faint crest constellation (atmosphere, not a vacancy board)
    crests = ["RMA", "BAR", "LIV", "JUV", "PSG", "INT", "ACM", "ATM", "ARS", "CHE"]
    crest_layer = Image.new("RGBA", (W, h), (0, 0, 0, 0))
    size = 52
    positions = [
        (70, 80), (160, 500), (980, 90), (920, 480),
        (30, 340), (1000, 300), (500, 560), (700, 30),
    ]
    for i, (cx, cy) in enumerate(positions):
        code = crests[i % len(crests)]
        bp = BADGE_DIR / f"{code}.png"
        if not bp.exists():
            continue
        badge = Image.open(bp).convert("RGBA")
        badge.thumbnail((size, size), Image.Resampling.LANCZOS)
        # darken + low alpha
        dark = Image.new("RGBA", badge.size, (0, 0, 0, 160))
        badge = Image.alpha_composite(badge, dark)
        a = badge.split()[-1].point(lambda p: int(p * 0.28))
        badge.putalpha(a)
        crest_layer.alpha_composite(badge, (cx, cy))
    crest_layer = crest_layer.filter(ImageFilter.GaussianBlur(0.6))
    canvas.alpha_composite(crest_layer)

    # soft vignette so edges dissolve into black
    vig = Image.new("L", (W, h), 0)
    vd = ImageDraw.Draw(vig)
    for y in range(h):
        for edge in (True, False):
            pass
        # vertical fade top/bottom of montage band
        t = y / max(h - 1, 1)
        if t < 0.08:
            a = int(255 * (t / 0.08))
        elif t > 0.88:
            a = int(255 * ((1 - t) / 0.12))
        else:
            a = 255
        vd.line([(0, y), (W, y)], fill=a)
    # horizontal side fade
    side = Image.new("L", (W, h), 255)
    sd = ImageDraw.Draw(side)
    for x in range(70):
        a = int(255 * (x / 70))
        sd.line([(x, 0), (x, h)], fill=a)
        sd.line([(W - 1 - x, 0), (W - 1 - x, h)], fill=a)
    mask = Image.composite(vig, Image.new("L", (W, h), 0), side)
    out = Image.new("RGBA", (W, h), (0, 0, 0, 0))
    out = Image.composite(canvas, out, mask)

    # light dark veil — montage should read, not vanish
    veil = Image.new("RGBA", (W, h), (5, 5, 5, 55))
    out = Image.alpha_composite(out, veil)
    return out


def main() -> None:
    img = Image.new("RGB", (W, H), BG)
    hero = hero_from_ai_or_stadium()
    img.paste(hero, (0, 0))
    draw = ImageDraw.Draw(img)

    f_eye = font(r"C:\Windows\Fonts\seguisb.ttf", 15)
    f_h1 = font(r"C:\Windows\Fonts\georgia.ttf", 78)
    f_sub = font(r"C:\Windows\Fonts\georgiai.ttf", 28)
    f_lab = font(r"C:\Windows\Fonts\seguisb.ttf", 15)
    f_body = font(r"C:\Windows\Fonts\segoeui.ttf", 18)
    f_foot = font(r"C:\Windows\Fonts\segoeui.ttf", 15)
    f_tag = font(r"C:\Windows\Fonts\georgiai.ttf", 20)

    def size(text, fnt):
        b = draw.textbbox((0, 0), text, font=fnt)
        return b[2] - b[0], b[3] - b[1]

    def center(text, y, fnt, fill):
        tw, th = size(text, fnt)
        draw.text(((W - tw) / 2, y), text, font=fnt, fill=fill)
        return th

    logo = Image.open(LOGO).convert("RGBA")
    lw = 300
    lh = int(logo.height * (lw / logo.width))
    logo = logo.resize((lw, lh), Image.Resampling.LANCZOS)
    plate = Image.new("RGBA", (lw + 80, lh + 50), (0, 0, 0, 0))
    pd = ImageDraw.Draw(plate)
    pd.ellipse([0, 10, lw + 80, lh + 40], fill=(0, 0, 0, 140))
    plate = plate.filter(ImageFilter.GaussianBlur(18))
    layer = img.convert("RGBA")
    lx = (W - lw) // 2
    ly = 56
    layer.alpha_composite(plate, (lx - 40, ly - 15))
    layer.alpha_composite(logo, (lx, ly))
    img = layer.convert("RGB")
    draw = ImageDraw.Draw(img)

    y = ly + lh + 36
    center("GP SUPER LEAGUE", y, f_eye, SILVER)
    y += 36

    line = "Own the club."
    tw, _ = size(line, f_h1)
    x = (W - tw) / 2
    draw.text((x + 2, y + 3), line, font=f_h1, fill=(0, 0, 0))
    draw.text((x, y), line, font=f_h1, fill=WHITE)
    y += 92
    center("Run everything that matters.", y, f_sub, ORANGE)
    y += 52
    draw.line([W // 2 - 28, y, W // 2 + 28, y], fill=ORANGE, width=2)
    y += 28

    # --- dark translucent montage behind the bands ---
    montage_top = y - 10
    montage_bottom = H - 130
    montage = build_lower_montage(montage_top, montage_bottom)
    layer = img.convert("RGBA")
    layer.alpha_composite(montage, (0, montage_top))
    img = layer.convert("RGB")
    draw = ImageDraw.Draw(img)

    bands = [
        (
            "MATCH DAY",
            "Propose kick-offs, check in, submit the score and walk the fixture "
            "on a club site built around how GPSL actually plays.",
        ),
        (
            "TRANSFER CENTRE",
            "Owner-to-owner deals, player draft auctions, special auctions, "
            "club drafts and manager auctions — then contract renewals that matter.",
        ),
        (
            "FINANCES",
            "Season wages, credit rating, ledgers, budgets and FFP pressure. "
            "Every signing hits the books. Every result feeds the forecast.",
        ),
        (
            "BESPOKE WEBSITE",
            "Built specifically for GPSL — not a shared multi-league template. "
            "Match Day, transfers and finances go deeper because the platform is ours.",
        ),
        (
            "TRUE COMPETITION",
            "GP-only · unique players, clubs, stadiums and managers · PA3 · "
            "60-club pyramid with promotion, relegation and playoffs.",
        ),
    ]

    left = 72
    label_w = 210
    text_x = left + label_w + 24
    text_w = W - text_x - 72

    for i, (label, body) in enumerate(bands):
        if i:
            draw.line([left, y, W - left, y], fill=RULE, width=1)
            y += 22

        # soft text plate for readability over montage
        words = body.split()
        lines = []
        cur = ""
        for w in words:
            trial = w if not cur else f"{cur} {w}"
            if size(trial, f_body)[0] <= text_w:
                cur = trial
            else:
                lines.append(cur)
                cur = w
        if cur:
            lines.append(cur)
        block_h = max(28, len(lines) * (size("Ay", f_body)[1] + 5) + 8)
        plate = Image.new("RGBA", (W - left * 2 + 16, block_h + 10), (0, 0, 0, 0))
        pd = ImageDraw.Draw(plate)
        pd.rounded_rectangle(
            [0, 0, plate.width - 1, plate.height - 1],
            radius=6,
            fill=(0, 0, 0, 110),
        )
        layer = img.convert("RGBA")
        layer.alpha_composite(plate, (left - 8, y - 4))
        img = layer.convert("RGB")
        draw = ImageDraw.Draw(img)

        draw.text((left, y + 2), label, font=f_lab, fill=ORANGE)
        by = y
        for ln in lines:
            draw.text((text_x, by), ln, font=f_body, fill=MUTED)
            by += size(ln, f_body)[1] + 5
        y = max(y + 28, by) + 16

    y = max(y + 8, H - 140)
    draw.line([left, y, W - left, y], fill=RULE, width=1)
    y += 26
    center(
        "Waiting list open  ·  Discord  ·  PC & Console  ·  GP-only  ·  PA3",
        y,
        f_foot,
        DIM,
    )
    y += 34
    center("More than just a match.", y, f_tag, (128, 128, 128))

    draw.rectangle([22, 22, W - 22, H - 22], outline=(34, 34, 34), width=1)

    img.save(OUT_PNG)
    img.save(OUT_JPG, quality=94)
    print(f"saved {OUT_PNG} {img.size}")


if __name__ == "__main__":
    main()
