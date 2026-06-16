#!/usr/bin/env python3
"""Download flag PNGs from flagcdn.com for nation codes in the catalog."""

from __future__ import annotations

import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "data" / "international_nation_catalog.json"
FLAGS_DIR = ROOT / "images" / "flags"


def main() -> None:
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    FLAGS_DIR.mkdir(parents=True, exist_ok=True)
    downloaded = 0
    skipped = 0
    for row in catalog:
        code = row["code"]
        slug = row.get("flagcdn_slug")
        if not slug:
            continue
        dest = FLAGS_DIR / f"{code}.png"
        if dest.exists():
            skipped += 1
            continue
        url = f"https://flagcdn.com/w80/{slug}.png"
        try:
            with urllib.request.urlopen(url, timeout=30) as resp:
                dest.write_bytes(resp.read())
            downloaded += 1
            print(f"OK {code} -> {dest.name}")
        except Exception as exc:  # noqa: BLE001
            print(f"SKIP {code} ({slug}): {exc}")
    print(f"Done: {downloaded} downloaded, {skipped} already present")


if __name__ == "__main__":
    main()
