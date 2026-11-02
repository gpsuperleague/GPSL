"""
Tweak attached AI recruit poster:
- replace broken crest with official GPSL logo (gold-warmed, no plate)
- remove repetitive bottom icon strip (keep Discord)
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageChops

ROOT = Path(__file__).resolve().parents[2]
PACK = Path(__file__).resolve().parent
ORIG = Path(
    r"C:\Users\Rotav\.cursor\projects\d-GPSL-Cursor\assets"
    r"\Designer__5_-934e7ba4-75b5-43b5-8dcd-533ff31ecd93.jpg"
)
LOGO = ROOT / "images" / "League" / "Logos" / "GPSL_logo.png"
OUT_PNG = PACK / "00-recruit-poster.png"
OUT_JPG = PACK / "00-recruit-poster.jpg"
OUT_ASSET = Path(
    r"C:\Users\Rotav\.cursor\projects\d-GPSL-Cursor\assets"
    r"\gpsl-recruit-poster-tweaked.jpg"
)


def prep_logo(path: Path) -> Image.Image:
    im = Image.open(path).convert("RGBA")
    px = im.load()
    w, h = im.size
    xs, ys = [], []
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a >= 120 and r + g + b > 55:
                xs.append(x)
                ys.append(y)
    pad = 6
    box = (
        max(0, min(xs) - pad),
        max(0, min(ys) - pad),
        min(w, max(xs) + pad + 1),
        min(h, max(ys) + pad + 1),
    )
    im = im.crop(box)
    out = Image.new("RGBA", im.size, (0, 0, 0, 0))
    s, d = im.load(), out.load()
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = s[x, y]
            if a >= 130 and r + g + b > 60:
                # gold cast to match poster
                r2 = min(255, int(r * 0.62 + 135))
                g2 = min(255, int(g * 0.52 + 95))
                b2 = min(255, int(b * 0.18 + 18))
                d[x, y] = (r2, g2, b2, 255)
    return out


def heal_region(poster: Image.Image, box: tuple[int, int, int, int], pad: int = 40) -> None:
    """Replace a region with a heavily blurred copy of its surroundings (no hard plate)."""
    x0, y0, x1, y1 = box
    W, H = poster.size
    sx0, sy0 = max(0, x0 - pad), max(0, y0 - pad)
    sx1, sy1 = min(W, x1 + pad), min(H, y1 + pad)
    context = poster.crop((sx0, sy0, sx1, sy1)).filter(ImageFilter.GaussianBlur(22))
    # punch a dark atmospheric mid so crest metal doesn't survive blur
    context = ImageEnhance.Brightness(context).enhance(0.55)
    context = ImageEnhance.Color(context).enhance(0.7)
    # take the inner box from blurred context
    ix0, iy0 = x0 - sx0, y0 - sy0
    patch = context.crop((ix0, iy0, ix0 + (x1 - x0), iy0 + (y1 - y0)))
    # soft circular-ish mask so edges dissolve into stadium
    bw, bh = patch.size
    mask = Image.new("L", (bw, bh), 0)
    ImageDraw.Draw(mask).ellipse(
        [int(bw * 0.02), int(bh * 0.02), int(bw * 0.98) - 1, int(bh * 0.98) - 1],
        fill=255,
    )
    mask = mask.filter(ImageFilter.GaussianBlur(14))
    poster.paste(patch, (x0, y0), mask)


def main() -> None:
    src = Image.open(ORIG).convert("RGB")
    W0, H0 = src.size
    print("orig", W0, H0)

    # heal crest zone (covers doubled shield + EST. 2023)
    heal_region(src, (int(W0 * 0.26), 0, int(W0 * 0.74), 155), pad=50)
    # second pass tighter and darker to kill residual crest edges
    heal_region(src, (int(W0 * 0.30), 4, int(W0 * 0.70), 148), pad=30)

    logo = prep_logo(LOGO)
    lw = int(W0 * 0.33)
    lh = max(1, int(logo.height * (lw / logo.width)))
    logo = logo.resize((lw, lh), Image.Resampling.LANCZOS)
    lx = (W0 - lw) // 2
    ly = 22
    layer = src.convert("RGBA")
    layer.alpha_composite(logo, (lx, ly))
    src = layer.convert("RGB")
    print("logo", lx, ly, lw, lh)

    # remove repetitive icon strip — dark fabric fill, not Discord clone
    ix0, iy0, ix1, iy1 = 55, 834, W0 - 55, 914
    fabric = src.crop((ix0, 818, ix1, 828)).resize(
        (ix1 - ix0, iy1 - iy0), Image.Resampling.BILINEAR
    )
    fabric = ImageEnhance.Brightness(fabric).enhance(0.9)
    fabric = fabric.filter(ImageFilter.GaussianBlur(1.2))
    bw, bh = ix1 - ix0, iy1 - iy0
    hmask = Image.new("L", (bw, bh), 255)
    hd = ImageDraw.Draw(hmask)
    for x in range(40):
        a = int(255 * (x / 40))
        hd.line([(x, 0), (x, bh)], fill=a)
        hd.line([(bw - 1 - x, 0), (bw - 1 - x, bh)], fill=a)
    vmask = Image.new("L", (bw, bh), 255)
    vd = ImageDraw.Draw(vmask)
    for y in range(8):
        a = int(255 * (y / 8))
        vd.line([(0, y), (bw, y)], fill=a)
        vd.line([(0, bh - 1 - y), (bw, bh - 1 - y)], fill=a)
    mask = ImageChops.multiply(hmask, vmask)
    base = src.crop((ix0, iy0, ix1, iy1))
    src.paste(Image.composite(fabric, base, mask), (ix0, iy0))

    out = src.resize((1080, int(H0 * (1080 / W0))), Image.Resampling.LANCZOS)
    out.save(OUT_PNG)
    out.save(OUT_JPG, quality=94)
    out.save(OUT_ASSET, quality=94)
    # also overwrite final asset path used earlier
    final = Path(r"C:\Users\Rotav\.cursor\projects\d-GPSL-Cursor\assets\gpsl-recruit-final.jpg")
    out.save(final, quality=94)
    print("saved", OUT_PNG, out.size)


if __name__ == "__main__":
    main()
