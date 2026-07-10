# GPSL International football & World Cup (v1)

## Overview

- **60 nations** — owners manage one national team each via draft selection.
- **World Cup every 4 GPSL seasons** — finals in **pre-season of S5, S9, …** (after two qualifying seasons).
- **Qualifying** — 2 seasons before finals; 12×5 groups; top 2 + 8 best third → 32 finalists.
- **Finals** — 8×4 groups; top 2 → R16 → QF → SF → Final.
- **Player international stats** — cumulative caps, goals, assists, POTM, clean sheets, average rating (`international_player_career`; overall, not per season).
- **Market value** — **+5%** after **4 international appearances** in the current national call-up, or if they reached 4 apps in the **previous** WC-cycle call-up (two squad windows). Applied in `gpsl_pv_*` / call-up & release / `international_record_callup_appearance`.

## Nation selection

1. Admin sets **rank points** per owner club (higher = earlier pick).
2. After **Season 1**, admin opens **initial** selection window.
3. Owners pick in order 1→60 on `nation_select.html`.
4. Nation **locked** until post–World Cup re-selection.
5. After each WC, admin runs **Complete WC + open re-selection** — rankings refresh, all nations free, `post_world_cup` draft by current rank.

## Competition engine (admin)

SQL patches (run in order):

1. `supabase/sql/patches/international_wc_competition_engine.sql`
2. `supabase/sql/patches/international_wc_competition_engine_part2.sql`

Admin UI: `admin_international.html` → **World Cup cycle**

| Step | Action |
|------|--------|
| Create cycle | Label + qual season 1 + qual season 2 + **finals season (pre-season)** e.g. S3 + S4 qual, S5 finals |
| Draw qual groups | Seed pots 1–5 (ranks 1–12, 13–24, …); one from each pot → groups A–L |
| Generate qual fixtures | Double RR in groups of 5: **8 games per nation** (4/season). 5 calendar windows/season (bye each round) spaced Aug–May; seasons 1 then 2 |
| Rank thirds | After all qual played: top 2 + 8 best thirds → 32 |
| Draw finals | 4 pots of 8 by seed among qualified → groups A–H |
| Generate finals fixtures | Single RR (6 per group) |
| Seed knockout | After finals groups played: R16 pairings → QF/SF/Final advance on results |
| Complete + re-select | Mark complete, recompute owner rankings, release nations, open draft |

## Owner matchday

- `international_matchday.html` — propose/accept kickoff, submit/confirm results, default squad JSON
- Career stats + call-up appearance (MV boost) update on confirm
- Standings recompute on group results; knockout winners advance automatically

## Pages

| Page | Purpose |
|------|---------|
| `world_cup.html` | Cycle info, qual/finals tables, knockout bracket |
| `international_matchday.html` | Arrange + results for your nation |
| `nation_select.html` | Owner draft pick |
| `national_team.html?nation=XXX` | Flag, squad, call-ups |
| `admin_international.html` | Admin setup + WC cycle |

## SQL

`supabase/sql/competition_international.sql` + WC engine patches above.

## Nation strength (admin)

1. **Refresh selectable nations** — import GPDB nationalities, rebuild pool cache, set `active` only for squad-viable nations (**≥24 GPDB players and ≥2 GKs**).
2. **Recompute seed ranks** — order active nations by **average rating of their top 100 GPDB players** (`seed_rank` 1 = strongest). Used for qualifying/finals pots; owner draft order stays on rolling owner rankings.

## Still thin / follow-ups

- Full pitch UI for intl default XI (currently JSON / club-parity RPCs; club matchday UI not fully reused yet)
- Check-in window parity with club matchday (intl uses agreed kickoff only for now)
- Calendar deep-links to specific intl fixtures by `gpsl_month`
