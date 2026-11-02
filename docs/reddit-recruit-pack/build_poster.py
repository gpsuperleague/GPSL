"""
GPSL Reddit invite poster — Pillow, from scratch.
Real aerial stadium photo + cropped GPSL logo + 6 available clubs + plain-English detail.
"""
from __future__ import annotations

import json
import urllib.request
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageEnhance

ROOT = Path(__file__).resolve().parents[2]
PACK = Path(__file__).resolve().parent
OUT_PNG = PACK / "00-recruit-poster.png"
OUT_JPG = PACK / "00-recruit-poster.jpg"
# Real aerial with city fabric — hard to mistake for eFootball art
STADIUM = ROOT / "images" / "stadiums" / "LIV.jpg"
BADGE_DIR = ROOT / "images" / "club_badges"

SUPABASE_URL = "https://omyyogfumrjoaweuawjn.supabase.co"
SUPABASE_ANON_KEY = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
    "eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9teXlvZ2Z1bXJqb2F3ZXVhd2puIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ5NTUxMzUsImV4cCI6MjA5MDUzMTEzNX0."
    "7UVkpi4DOtC9VNjFLnE_ZnK6vhDtlfesZ_8rfnrkno4"
)

FALLBACK_AVAILABLE = [
    ("ATM", "Atlético Madrid"),
    ("INT", "Inter Milan"),
    ("LEV", "Leverkusen"),
    ("LIV", "Liverpool"),
    ("MAR", "Marseille"),
    ("AVL", "Aston Villa"),
]

W, H = 1080, 1550
ORANGE = (255, 153, 0)
WHITE = (245, 245, 245)
MUTED = (188, 188, 188)
DIM = (145, 145, 145)
PANEL_FILL = (10, 10, 12, 220)
PANEL_EDGE = (55, 48, 28)


def font(path: str, size: int) -> ImageFont.ImageFont:
    try:
        return ImageFont.truetype(path, size)
    except Exception:
        return ImageFont.load_default()


def cover(src: Image.Image, tw: int, th: int, bias_y: float = 0.4) -> Image.Image:
    sw, sh = src.size
    scale = max(tw / sw, th / sh)
    nw, nh = int(sw * scale), int(sh * scale)
    im = src.resize((nw, nh), Image.Resampling.LANCZOS)
    left = (nw - tw) // 2
    top = int(max(0, (nh - th) * bias_y))
    return im.crop((left, top, left + tw, top + th))


def fetch_available_clubs(limit: int = 6) -> list[tuple[str, str]]:
    headers = {
        "apikey": SUPABASE_ANON_KEY,
        "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
    }
    out: list[tuple[str, str]] = []
    seen: set[str] = set()

    def add(code: str, name: str) -> None:
        code = code.strip().upper()
        if not code or code in seen or code == "FOREIGN":
            return
        if not (BADGE_DIR / f"{code}.png").exists():
            return
        seen.add(code)
        out.append((code, name.strip() or code))

    try:
        req = urllib.request.Request(
            f"{SUPABASE_URL}/rest/v1/Clubs?handpick_intake=eq.true"
            "&select=ShortName,Club&order=Club",
            headers=headers,
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            for row in json.loads(resp.read().decode()):
                add(str(row.get("ShortName") or ""), str(row.get("Club") or ""))
                if len(out) >= limit:
                    return out[:limit]
    except Exception as e:
        print("handpick fetch failed:", e)

    notables = [
        "FIO", "AVL", "LAZ", "ROM", "VAL", "BET", "CEL", "FEY",
        "SPO", "PSV", "MCI", "RMA", "MUN", "TOT",
    ]
    try:
        q = ",".join(notables)
        req = urllib.request.Request(
            f"{SUPABASE_URL}/rest/v1/Clubs?owner_id=is.null"
            f"&ShortName=in.({q})&select=ShortName,Club&order=Club",
            headers=headers,
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            for row in json.loads(resp.read().decode()):
                add(str(row.get("ShortName") or ""), str(row.get("Club") or ""))
                if len(out) >= limit:
                    return out[:limit]
    except Exception as e:
        print("vacant fetch failed:", e)

    for code, name in FALLBACK_AVAILABLE:
        add(code, name)
        if len(out) >= limit:
            break
    return out[:limit]


def circle_badge(path: Path, size: int) -> Image.Image:
    im = Image.open(path).convert("RGBA")
    im.thumbnail((size - 10, size - 10), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    disc = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(disc)
    d.ellipse(
        [0, 0, size - 1, size - 1],
        fill=(14, 14, 14, 240),
        outline=(255, 153, 0, 200),
        width=2,
    )
    canvas.alpha_composite(disc)
    canvas.alpha_composite(im, ((size - im.width) // 2, (size - im.height) // 2))
    return canvas


def wrap(draw: ImageDraw.ImageDraw, text: str, fnt, max_w: int) -> list[str]:
    words = text.split()
    lines, cur = [], ""
    for w in words:
        trial = w if not cur else f"{cur} {w}"
        b = draw.textbbox((0, 0), trial, font=fnt)
        if b[2] - b[0] <= max_w:
            cur = trial
        else:
            if cur:
                lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def main() -> None:
    available = fetch_available_clubs(6)
    print("available:", available)

    # --- background: real aerial stadium, soft darken (keep city detail) ---
    stadium = cover(Image.open(STADIUM).convert("RGB"), W, H, bias_y=0.55)
    stadium = ImageEnhance.Brightness(stadium).enhance(0.55)
    stadium = ImageEnhance.Contrast(stadium).enhance(1.08)
    stadium = ImageEnhance.Color(stadium).enhance(0.85)
    wash = Image.new("RGB", (W, H), (8, 8, 10))
    img = Image.blend(stadium, wash, 0.38)

    # gradient: darker top for logo/type, mid readable, bottom for CTA
    fade = Image.new("L", (W, H), 0)
    fd = ImageDraw.Draw(fade)
    for y in range(H):
        t = y / (H - 1)
        if t < 0.18:
            a = 210
        elif t < 0.38:
            a = int(210 - 100 * ((t - 0.18) / 0.20))
        elif t < 0.72:
            a = 110
        else:
            a = int(110 + 90 * ((t - 0.72) / 0.28))
        fd.line([(0, y), (W, y)], fill=max(0, min(255, a)))
    img = Image.composite(img, wash, fade)
    draw = ImageDraw.Draw(img)

    f_mark = font(r"C:\Windows\Fonts\arialbd.ttf", 72)
    f_eye = font(r"C:\Windows\Fonts\seguisb.ttf", 13)
    f_h1 = font(r"C:\Windows\Fonts\georgia.ttf", 58)
    f_sub = font(r"C:\Windows\Fonts\georgiai.ttf", 22)
    f_body = font(r"C:\Windows\Fonts\segoeui.ttf", 15)
    f_panel_t = font(r"C:\Windows\Fonts\seguisb.ttf", 13)
    f_panel_b = font(r"C:\Windows\Fonts\segoeui.ttf", 12)
    f_club = font(r"C:\Windows\Fonts\segoeui.ttf", 11)
    f_foot = font(r"C:\Windows\Fonts\segoeui.ttf", 13)
    f_tag = font(r"C:\Windows\Fonts\georgiai.ttf", 17)
    f_cta = font(r"C:\Windows\Fonts\seguisb.ttf", 15)

    def size(text, fnt):
        b = draw.textbbox((0, 0), text, font=fnt)
        return b[2] - b[0], b[3] - b[1]

    def center(text, y, fnt, fill):
        tw, th = size(text, fnt)
        draw.text(((W - tw) / 2, y), text, font=fnt, fill=fill)
        return y + th

    # --- single GPSL mark (one text draw only — no shadow / no PNG) ---
    y = 44
    mark = "GPSL"
    # Use absolute textbbox so descenders/padding don't overlap the rule below
    mw, _ = size(mark, f_mark)
    mx = (W - mw) / 2
    draw.text((mx, y), mark, font=f_mark, fill=(235, 235, 235))
    ink = draw.textbbox((mx, y), mark, font=f_mark)
    rule_w = 56
    rule_y = ink[3] + 12
    draw.rectangle(
        [(W - rule_w) / 2, rule_y, (W + rule_w) / 2, rule_y + 2],
        fill=ORANGE,
    )
    y = rule_y + 14
    y = center("GP SUPER LEAGUE", y, f_eye, DIM) + 12
    y = center("You're invited.", y, f_h1, WHITE) + 8
    y = center("Own a club in the GP Super League.", y, f_sub, ORANGE) + 10
    for line in (
        "A community Master League on eFootball — run on a website",
        "built only for GPSL, not a shared multi-league template.",
    ):
        y = center(line, y, f_body, MUTED) + 2
    y += 18

    # --- 6 available clubs ---
    n = len(available)
    y = center(f"CLUBS AVAILABLE NOW  ·  {n}", y, f_eye, ORANGE) + 12

    badge = 72
    gap = 16
    total_w = n * badge + (n - 1) * gap
    x0 = (W - total_w) // 2
    layer = img.convert("RGBA")
    for i, (code, name) in enumerate(available):
        b = circle_badge(BADGE_DIR / f"{code}.png", badge)
        bx = x0 + i * (badge + gap)
        layer.alpha_composite(b, (bx, y))
    img = layer.convert("RGB")
    draw = ImageDraw.Draw(img)
    y += badge + 5
    for i, (code, name) in enumerate(available):
        label = name if len(name) <= 13 else code
        tw, _ = size(label, f_club)
        bx = x0 + i * (badge + gap) + (badge - tw) // 2
        draw.text((bx, y), label, font=f_club, fill=DIM)
    y += 26

    # --- human-readable categories (no leading dashes) ---
    panels = [
        (
            "Match Day",
            "You and your opponent agree a kick-off, both check in on the site, "
            "play the match, then enter the score and key stats. Fixtures, "
            "results and form all live in one place.",
        ),
        (
            "Transfer market",
            "Buy and sell with other owners — negotiate fees, move players, "
            "and live with the wage bill that comes with every deal.",
        ),
        (
            "Player drafts",
            "When the league opens a draft window, free agents go up for bids. "
            "Timed rounds; highest bid takes the player.",
        ),
        (
            "Special auctions",
            "Featured one-offs and event lots beyond the day-to-day market — "
            "big names and oddities when the league puts them up.",
        ),
        (
            "Club auctions",
            "Before a season, vacant clubs go to auction. You bid for the seat "
            "you want, then build from that squad.",
        ),
        (
            "Manager auctions",
            "Hire your manager at auction. Their style and contract matter — "
            "and when the deal ends, they can go back to market.",
        ),
        (
            "Contract renewals",
            "Players and managers expire. Keep them, let them walk, or watch "
            "them hit the market for someone else.",
        ),
        (
            "Club finances",
            "Season wages, ledgers, credit rating, budgets and FFP pressure. "
            "Every signing hits the books — overspend and you feel it.",
        ),
        (
            "Divisions & promotion",
            "Sixty clubs across three divisions. Win your league, go up. "
            "Struggle, go down. Tables update as results come in.",
        ),
        (
            "Discipline & fair play",
            "Missed kick-offs and no-shows carry fines and strikes. The rules "
            "are written down so everyone plays by the same clock.",
        ),
        (
            "Bespoke GPSL website",
            "Not a shared multi-league template. Match Day, transfers, auctions "
            "and finances go deeper because the platform is built for us.",
        ),
        (
            "How we play",
            "GP-only squads. Unique players, clubs, stadiums and managers. "
            "PA3. Smart Assist banned. PC and console welcome.",
        ),
    ]

    margin = 48
    gap_x, gap_y = 10, 8
    cols = 2
    col_w = (W - margin * 2 - gap_x * (cols - 1)) // cols
    panel_h = 92
    rows = (len(panels) + cols - 1) // cols

    # fit remaining space
    room = H - y - 110
    need = rows * (panel_h + gap_y)
    if need > room:
        panel_h = max(78, int((room - rows * gap_y) / rows))

    layer = img.convert("RGBA")
    pd = ImageDraw.Draw(layer)

    for idx, (title, body) in enumerate(panels):
        r, c = divmod(idx, cols)
        px = margin + c * (col_w + gap_x)
        py = y + r * (panel_h + gap_y)

        # panel plate
        plate = Image.new("RGBA", (col_w, panel_h), (0, 0, 0, 0))
        pdraw = ImageDraw.Draw(plate)
        pdraw.rounded_rectangle(
            [0, 0, col_w - 1, panel_h - 1],
            radius=7,
            fill=PANEL_FILL,
            outline=(*PANEL_EDGE, 255),
            width=1,
        )
        layer.alpha_composite(plate, (px, py))

        # title only — no leading dash / accent bar
        pd.text((px + 14, py + 10), title, font=f_panel_t, fill=ORANGE)
        lines = wrap(pd, body, f_panel_b, col_w - 28)
        by = py + 32
        line_h = size("Ag", f_panel_b)[1] + 2
        max_lines = max(2, (panel_h - 40) // line_h)
        for ln in lines[:max_lines]:
            pd.text((px + 12, by), ln, font=f_panel_b, fill=MUTED)
            by += line_h

    img = layer.convert("RGB")
    draw = ImageDraw.Draw(img)
    y = y + rows * (panel_h + gap_y) + 14

    # CTA
    cta = "JOIN THE WAITING LIST"
    tw, th = size(cta, f_cta)
    cw, ch = tw + 52, th + 20
    cx = (W - cw) // 2
    if y + ch + 56 > H - 20:
        y = H - 90
    draw.rectangle([cx, y, cx + cw, y + ch], fill=ORANGE)
    draw.text((cx + 26, y + 9), cta, font=f_cta, fill=(17, 17, 17))
    y += ch + 10
    center("Discord  ·  PC & Console  ·  GP-only  ·  PA3", y, f_foot, DIM)
    y += 24
    center("More than just a match.", y, f_tag, (150, 150, 150))

    draw.rectangle([18, 18, W - 18, H - 18], outline=(42, 42, 42), width=1)

    img.save(OUT_PNG)
    img.save(OUT_JPG, quality=94)
    print(f"saved {OUT_PNG}")


if __name__ == "__main__":
    main()
