"""Generate managers_seed_data.sql from data/Managers.xlsx."""

import json
import re
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
XLSX = ROOT / "data" / "Managers.xlsx"
TABLES = ROOT / "data" / "manager_value_tables.json"
OUT = ROOT / "supabase" / "sql" / "patches" / "managers_seed_data.sql"


def playstyle_tier_value(rating: int, tiers: list) -> int:
    r = int(round(rating))
    for tier in tiers:
        if tier["min"] <= r <= tier["max"]:
            return int(tier["value"])
    if r > 90 and tiers:
        return int(tiers[-1]["value"])
    return 0


def manager_market_value(styles: list[int], tiers: list) -> int:
    return sum(playstyle_tier_value(s, tiers) for s in styles)


def slug(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", name.lower().strip())
    return s.strip("-")


def sql_quote(value: str) -> str:
    return str(value).replace("'", "''")


def main() -> None:
    df = pd.read_excel(XLSX)
    with TABLES.open(encoding="utf-8") as f:
        tiers = json.load(f)["playstyleTiers"]

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
        mv = manager_market_value(styles, tiers)
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
        f"-- {len(rows)} managers (MV = sum of playstyle tier values)",
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
