from PIL import Image
from pathlib import Path
import math

assets = Path(r"C:\Users\Rotav\.cursor\projects\d-GPSL-Cursor\assets")
out_dir = Path(r"d:\GPSL_Cursor\assets\discord-roles")
out_dir.mkdir(parents=True, exist_ok=True)

sources = {
    "visitor": assets / "discord-role-visitor-key.jpg",
    "member": assets / "discord-role-member-key.jpg",
    "owner": assets / "discord-role-owner-key.jpg",
}


def dist(a, b):
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a[:3], b[:3])))


def key_background(im: Image.Image) -> Image.Image:
    im = im.convert("RGBA")
    w, h = im.size
    px = im.load()
    # Sample corners for key color
    keys = [px[0, 0][:3], px[w - 1, 0][:3], px[0, h - 1][:3], px[w - 1, h - 1][:3]]
    key = tuple(int(sum(c[i] for c in keys) / 4) for i in range(3))

    # Flood from edges using distance to key color
    stack = []
    for x in range(w):
        stack.append((x, 0))
        stack.append((x, h - 1))
    for y in range(h):
        stack.append((0, y))
        stack.append((w - 1, y))

    visited = set()
    while stack:
        x, y = stack.pop()
        if (x, y) in visited or x < 0 or y < 0 or x >= w or y >= h:
            continue
        visited.add((x, y))
        p = px[x, y]
        if dist(p, key) > 55:
            continue
        px[x, y] = (0, 0, 0, 0)
        stack.extend([(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)])

    # Also punch remaining key color inside shapes (e.g. pink field in owner crest)
    for y in range(h):
        for x in range(w):
            if px[x, y][3] == 0:
                continue
            if dist(px[x, y], key) <= 55:
                px[x, y] = (0, 0, 0, 0)

    # Clean anti-aliased fringe near transparent
    for y in range(h):
        for x in range(w):
            if px[x, y][3] == 0:
                continue
            if dist(px[x, y], key) > 70:
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h and px[nx, ny][3] == 0:
                    px[x, y] = (0, 0, 0, 0)
                    break
    return im


def square_crop_to_content(im: Image.Image) -> Image.Image:
    box = im.split()[-1].getbbox()
    if not box:
        return im
    x0, y0, x1, y1 = box
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    side = max(x1 - x0, y1 - y0) * 1.04
    half = side / 2
    crop = (
        int(max(0, cx - half)),
        int(max(0, cy - half)),
        int(min(im.width, cx + half)),
        int(min(im.height, cy + half)),
    )
    return im.crop(crop)


for name, src in sources.items():
    if not src.exists():
        print("missing", src)
        continue
    im = key_background(Image.open(src))
    im = square_crop_to_content(im)
    im64 = im.resize((64, 64), Image.Resampling.LANCZOS)
    im256 = im.resize((256, 256), Image.Resampling.LANCZOS)
    p64 = out_dir / f"gpsl-role-{name}-64.png"
    p256 = out_dir / f"gpsl-role-{name}-256.png"
    im64.save(p64, "PNG")
    im256.save(p256, "PNG")
    print(name, f"{p64.stat().st_size}B", p64.name)

print("done")
