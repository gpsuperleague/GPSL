"""Generate managers_seed_data.sql from data/Managers.xlsx."""

import json
import re
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
XLSX = ROOT / "data" / "Managers.xlsx"
TABLES = ROOT / "data" / "player_value_tables.json"
OUT = ROOT / "supabase" / "sql" / "patches" / "managers_seed_data.sql"


def base_mv(rating: int, bmap: dict) -> int:
    r = int(round(rating))
    key = str(r)
    if key in bmap:
        return int(bmap[key])
    keys = sorted(int(x) for x in bmap)
    if r <= keys[0]:
        return int(bmap[str(keys[0])])
    if r >= keys[-1]:
        return int(bmap[str(keys[-1])])
    for i in range(len(keys) - 1):
        lo, hi = keys[i], keys[i + 1]
        if lo <= r <= hi:
            v_lo = int(bmap[str(lo)])
            v_hi = int(bmap[str(hi)])
            t = (r - lo) / (hi - lo)
            return int(v_lo + t * (v_hi - v_lo))
    return 0


def slug(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", name.lower().strip())
    return s.strip("-")


def sql_quote(value: str) -> str:
    return str(value).replace("'", "''")


def main() -> None:
    df = pd.read_excel(XLSX)
    with TABLES.open(encoding="utf-8") as f:
        bmap = json.load(f)["baseValueByRating"]

    rows = []
    seen_slugs: dict[str, int] = {}
    skipped_dupes = 0

    for _, r in df.iterrows():
        base_slug = slug(r["Manager Name"])
        if base_slug in seen_slugs:
            skipped_dupes += 1
            continue
        seen_slugs[base_slug] = 1

        styles = [
            int(r["Possession"]),
            int(r["Quick Counter"]),
            int(r["Long Ball Counter"]),
            int(r["Out Wide"]),
            int(r["Long Ball"]),
        ]
        rating = max(styles)
        age = int(r["Age"])
        if age >= 70:
            age_mult = 0.65
        elif age >= 65:
            age_mult = 0.75
        elif age >= 60:
            age_mult = 0.85
        elif age >= 55:
            age_mult = 0.95
        else:
            age_mult = 1.0
        mv = max(250_000, int(base_mv(rating, bmap) * 0.20 * age_mult))
        rows.append(
            {
                "slug": base_slug,
                "name": sql_quote(r["Manager Name"]),
                "nation": sql_quote(r["Nation"]),
                "possession": styles[0],
                "quick_counter": styles[1],
                "long_ball_counter": styles[2],
                "out_wide": styles[3],
                "long_ball": styles[4],
                "age": age,
                "rating": rating,
                "mv": mv,
            }
        )

    if skipped_dupes:
        print(f"Skipped {skipped_dupes} duplicate row(s) in spreadsheet (same slug).")

    lines = [
        "-- Auto-generated from data/Managers.xlsx — re-run: python scripts/generate_managers_seed.py",
        f"-- {len(rows)} managers",
        "",
        'INSERT INTO public."Managers"',
        "  (slug, name, nation, possession, quick_counter, long_ball_counter, out_wide, long_ball, age, rating, market_value)",
        "VALUES",
    ]
    value_lines = [
        "  ('{slug}', '{name}', '{nation}', {possession}, {quick_counter}, {long_ball_counter}, "
        "{out_wide}, {long_ball}, {age}, {rating}, {mv})".format(**x)
        for x in rows
    ]
    lines.append(",\n".join(value_lines))
    lines.extend(
        [
            "ON CONFLICT (slug) DO UPDATE SET",
            "  name = EXCLUDED.name,",
            "  nation = EXCLUDED.nation,",
            "  possession = EXCLUDED.possession,",
            "  quick_counter = EXCLUDED.quick_counter,",
            "  long_ball_counter = EXCLUDED.long_ball_counter,",
            "  out_wide = EXCLUDED.out_wide,",
            "  long_ball = EXCLUDED.long_ball,",
            "  age = EXCLUDED.age,",
            "  rating = EXCLUDED.rating,",
            "  market_value = EXCLUDED.market_value;",
            "",
        ]
    )
    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"Wrote {OUT} ({len(rows)} rows)")


if __name__ == "__main__":
    main()
