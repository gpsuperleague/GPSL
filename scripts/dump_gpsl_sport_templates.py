#!/usr/bin/env python3
"""Dump GPSL Sport newspaper templates for copy expansion."""
from __future__ import annotations

import csv
import re
from pathlib import Path

ROOT = Path(r"d:\GPSL_Cursor\supabase\sql\patches")
OUT_TXT = Path(r"d:\GPSL_Cursor\gpsl_sport_templates_dump.txt")
OUT_CSV = Path(r"d:\GPSL_Cursor\gpsl_sport_templates_dump.csv")

FILES = [
    "gpsl_sport_phase1.sql",
    "gpsl_sport_preseason_phase2.sql",
    "gpsl_sport_preseason_phase3.sql",
    "gpsl_sport_may_preseason.sql",
    "gpsl_sport_inseason_rich_edition.sql",
    "gpsl_sport_motm_longform.sql",
    "gpsl_sport_standings_snapshot.sql",
    "gpsl_sport_may_relegation_fix.sql",
    "gpsl_sport_visual_heroes.sql",
]

# Balanced-ish ARRAY[...] finder (non-greedy until matching ] at paren depth 0 inside)
PAT_ARRAY = re.compile(r"ARRAY\s*\[", re.I)
PAT_STR = re.compile(r"(?:E)?'((?:''|\\'|[^'])*)'")
PAT_SEED = re.compile(r"pick_template\(\s*[^,]+?\|\|\s*'(?P<seed>:[a-z0-9]+)'", re.I)
PAT_STORY = re.compile(
    r"v_story_type\s*=\s*'([^']+)'|story_type['\"],\s*'([^']+)'|story_kind['\"],\s*'([^']+)'",
    re.I,
)


def unescape_sql(s: str) -> str:
    return (
        s.replace("''", "'")
        .replace(r"\n", "\n")
        .replace(r"\'", "'")
        .replace(r"\\", "\\")
    )


def extract_array_body(text: str, start_bracket: int) -> tuple[str, int] | None:
    """start_bracket points at '[' after ARRAY. Return (body, end_index_after_])."""
    i = start_bracket + 1
    depth = 1
    in_str = False
    esc = False
    while i < len(text):
        ch = text[i]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == "'":
                # SQL '' escape
                if i + 1 < len(text) and text[i + 1] == "'":
                    i += 1
                else:
                    in_str = False
            i += 1
            continue
        if ch == "'":
            in_str = True
            i += 1
            continue
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                return text[start_bracket + 1 : i], i + 1
        i += 1
    return None


def guess_field(ctx: str, seed: str) -> str:
    blob = (ctx + " " + seed).lower()
    if ":h" == seed or "headline" in blob or "v_headlines" in blob:
        return "headline"
    if ":s" == seed or "subhead" in blob or "v_subheads" in blob:
        return "subhead"
    if ":b" == seed or "v_bodies" in blob or "lead_body" in blob:
        return "body"
    if seed in (":op", ":mp", ":tp") or "pull" in blob or "quote" in blob:
        return "pull_quote"
    if ":oh" == seed:
        return "headline"
    if ":mh" == seed:
        return "headline"
    if ":xfer" == seed:
        return "headline"
    if "blurb" in blob:
        return "blurb"
    return "text"


def guess_scenario(ctx: str, seed: str) -> str:
    blob = (ctx + " " + seed).lower()
    mapping = [
        (r"shock_result|:h.*shock|stun", "shock_result"),
        (r"cup_upset|giant-kill|cup earthquake", "cup_upset"),
        (r"manager_pressure|under pressure|crisis", "manager_pressure"),
        (r"poor_start", "poor_start"),
        (r"roundup|round-up", "roundup"),
        (r":oh|owner_takeover|takes the helm|new era|new owner", "owner_takeover"),
        (r":mh|:mp|manager_signing|takes charge|dugout|manager draft", "manager_signing"),
        (r":xfer|:tp|transfer|splash|blockbuster", "transfer"),
        (r"preseason|pre-season|quiet", "preseason"),
        (r"motm|match of the month", "motm"),
        (r"standings|climber|defence|golden boot", "standings"),
        (r"season_review|may ", "season_review"),
    ]
    for pat, name in mapping:
        if re.search(pat, blob, re.I):
            return name
    if seed == ":oh":
        return "owner_takeover"
    if seed == ":mh" or seed == ":mp":
        return "manager_signing"
    if seed in (":xfer", ":tp"):
        return "transfer"
    if seed == ":op":
        return "owner_takeover"
    return "unknown"


def nearest_seed(text: str, pos: int) -> str:
    window = text[max(0, pos - 200) : pos]
    m = list(PAT_SEED.finditer(window))
    if m:
        return m[-1].group("seed")
    return ""


def nearest_story(text: str, pos: int) -> str:
    window = text[max(0, pos - 400) : pos]
    matches = list(PAT_STORY.finditer(window))
    if not matches:
        return ""
    m = matches[-1]
    return m.group(1) or m.group(2) or m.group(3) or ""


def extract_file(path: Path) -> list[dict]:
    text = path.read_text(encoding="utf-8", errors="replace")
    rows: list[dict] = []
    for m in PAT_ARRAY.finditer(text):
        bracket = m.end() - 1  # points at [
        got = extract_array_body(text, bracket)
        if not got:
            continue
        body, _ = got
        strings = [unescape_sql(s) for s in PAT_STR.findall(body)]
        # Keep story-like lines; drop tiny tokens
        strings = [s.strip() for s in strings if len(s.strip()) >= 10]
        # Skip pure expression arrays without readable prose
        prose = [s for s in strings if re.search(r"[A-Za-z]{4}", s)]
        if len(prose) < 2:
            continue
        ctx = re.sub(r"\s+", " ", text[max(0, m.start() - 240) : m.start()])[-200:]
        seed = nearest_seed(text, m.start())
        story = nearest_story(text, m.start())
        scenario = story or guess_scenario(ctx, seed)
        field = guess_field(ctx, seed)
        for i, s in enumerate(prose, 1):
            rows.append(
                {
                    "source_file": path.name,
                    "scenario": scenario,
                    "field": field,
                    "seed_suffix": seed,
                    "variant_index": i,
                    "template": s,
                    "placeholders": ",".join(sorted(set(re.findall(r"\{\{([A-Z0-9_]+)\}\}", s)))),
                }
            )
    return rows


CATALOG = """
================================================================================
SCENARIO CATALOG (for your CSV expansion)
================================================================================
Use these scenario keys when adding many random templates. Fields to expand:
  headline | subhead | body | pull_quote | blurb

PRESEASON
  owner_takeover          - new owner assigned / club auction win
                            placeholders: OWNER, CLUB, MONTH; bodies also branch on
                            assign_source: club_auction | admin_assign | default
  manager_signing         - manager draft / dugout appointment
                            placeholders: MANAGER, CLUB, MONTH, FEE, rating via format()
  transfer                - big fee transfer lead + pull quotes
                            placeholders: BUYER, SELLER, PLAYER, FEE, MONTH
  preseason_quiet         - no big moves yet (mostly fixed format() copy)
  preseason_pending       - waiting for auction/window activity

IN-SEASON (Aug-Apr)
  shock_result            - prestige/favourite upset in league
                            placeholders: WINNER, LOSER, SCORE, DIVISION, MONTH
                            (rich edition also: WINNER_OWNER, LOSER_OWNER)
  cup_upset               - knockout giant-killing
  manager_pressure        - big/prestige club underperforming
                            placeholders: WINNER(=club), POINTS, POSITION, DIVISION, MONTH
  poor_start              - medium club off expected pace
  roundup                 - generic monthly wrap when no shock
  motm                    - Match of the Month report (mostly format() chains + pull-quote bank)
  standings               - climber / home form / away form / goals / defence blurbs
  transfer (in-season)    - monthly transfer round-up headlines (format-heavy)

MAY
  season_review           - champions, promo/rel, cups, awards (CASE/format heavy)

ENGINE
  gpsl_sport_pick_template(seed, text[])  - deterministic random from array
  gpsl_sport_apply_template(tpl, jsonb)   - replaces {{KEY}} (keys uppercased)

AUTHORITATIVE SQL (later patches win)
  Preseason : gpsl_sport_preseason_phase3.sql (+ owner story in phase2 still used)
  In-season : gpsl_sport_inseason_rich_edition.sql
              + gpsl_sport_motm_longform.sql
              + gpsl_sport_standings_snapshot.sql
  May       : gpsl_sport_may_preseason.sql / may_relegation_fix.sql
  Legacy    : gpsl_sport_phase1.sql still has the biggest ARRAY banks for shock/cup/pressure

CSV FEEDBACK FORMAT (suggested columns)
  scenario,field,template,placeholders,notes,priority
  Example:
  shock_result,headline,"{{WINNER}} SHOCK THE LEAGUE - {{LOSER}} CRUMBLE {{SCORE}}","WINNER,LOSER,SCORE",new variant,high
"""


def main() -> None:
    all_rows: list[dict] = []
    lines: list[str] = []
    lines.append("GPSL SPORT — NEWSPAPER TEMPLATE DUMP")
    lines.append("Grab this file + gpsl_sport_templates_dump.csv to expand variants.")
    lines.append("")
    lines.append(CATALOG.strip())
    lines.append("")

    for fn in FILES:
        p = ROOT / fn
        if not p.exists():
            lines.append(f"[missing] {fn}")
            continue
        rows = extract_file(p)
        all_rows.extend(rows)
        lines.append("=" * 88)
        lines.append(f"FILE: {fn}  — {len(rows)} ARRAY template lines")
        lines.append("=" * 88)
        key = None
        for r in rows:
            k = (r["scenario"], r["field"], r["seed_suffix"])
            if k != key:
                key = k
                lines.append("")
                lines.append(
                    f"--- scenario={r['scenario']} | field={r['field']} | seed={r['seed_suffix'] or '—'} ---"
                )
            one = r["template"].replace("\n", " / ")
            lines.append(f"  [{r['variant_index']}] {one}")
        lines.append("")

    lines.append("=" * 88)
    lines.append("FORMAT()/CASE-ONLY COPY (not always in ARRAY banks)")
    lines.append("See these files for additional prose to rewrite/expand:")
    lines.append("  - gpsl_sport_preseason_phase2.sql :: gpsl_sport_build_owner_story bodies")
    lines.append("  - gpsl_sport_preseason_phase3.sql :: manager bodies, quiet/pending leads")
    lines.append("  - gpsl_sport_inseason_rich_edition.sql :: MotM short lead, transfer round-up")
    lines.append("  - gpsl_sport_motm_longform.sql :: full match report + pull-quote CASE bank")
    lines.append("  - gpsl_sport_standings_snapshot.sql :: standings highlight blurbs")
    lines.append("  - gpsl_sport_may_preseason.sql :: May season_review CASE headlines/leads")
    lines.append("=" * 88)

    OUT_TXT.write_text("\n".join(lines), encoding="utf-8")
    with OUT_CSV.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(
            f,
            fieldnames=[
                "scenario",
                "field",
                "seed_suffix",
                "variant_index",
                "template",
                "placeholders",
                "source_file",
                "notes_for_new_variants",
            ],
        )
        w.writeheader()
        for r in all_rows:
            w.writerow(
                {
                    **{k: r[k] for k in ("scenario", "field", "seed_suffix", "variant_index", "placeholders", "source_file")},
                    "template": r["template"].replace("\n", "\\n"),
                    "notes_for_new_variants": "",
                }
            )

    # Also write empty feedback template CSV
    feedback = Path(r"d:\GPSL_Cursor\gpsl_sport_templates_FEEDBACK.csv")
    with feedback.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(
            f,
            fieldnames=["scenario", "field", "template", "placeholders", "notes", "priority"],
        )
        w.writeheader()
        w.writerow(
            {
                "scenario": "shock_result",
                "field": "headline",
                "template": "{{WINNER}} SHOCK THE LEAGUE — {{LOSER}} CRUMBLE {{SCORE}}",
                "placeholders": "WINNER,LOSER,SCORE",
                "notes": "example row — delete and add your variants",
                "priority": "high",
            }
        )

    print(f"Wrote {OUT_TXT} ({OUT_TXT.stat().st_size} bytes)")
    print(f"Wrote {OUT_CSV} ({len(all_rows)} rows)")
    print(f"Wrote {feedback} (blank feedback sheet)")


if __name__ == "__main__":
    main()
