# GPSL International football & World Cup (v1)

## Overview

- **60 nations** — owners manage one national team each via draft selection.
- **World Cup every 4 GPSL seasons** — finals between S4–5, S8–9, …
- **Qualifying** — 2 seasons before finals; 12×5 groups; top 2 + 8 best third → 32 finalists.
- **Finals** — 8×4 groups; top 2 → R16 → QF → SF → Final.
- **Player international stats** — cumulative caps, goals, assists, POTM, clean sheets, average rating (`international_player_career`; overall, not per season).
- **Market value** — **+5%** after **4 international appearances** in the current national call-up, or if they reached 4 apps in the **previous** WC-cycle call-up (two squad windows). Applied in `gpsl_pv_*` / call-up & release / `international_record_callup_appearance`.

## Nation selection

1. Admin sets **rank points** per owner club (higher = earlier pick).
2. After **Season 1**, admin opens **initial** selection window.
3. Owners pick in order 1→60 on `nation_select.html`.
4. Nation **locked** until post–World Cup re-selection.
5. After each WC, admin opens **post_world_cup** window — all nations free; draft order by current rank (top owners can take nations previously held by lower-ranked owners if they pick first).

## Pages

| Page | Purpose |
|------|---------|
| `world_cup.html` | Cycle info, qual/finals group tables |
| `nation_select.html` | Owner draft pick |
| `national_team.html?nation=XXX` | Flag, squad, call-ups |
| `admin_international.html` | Admin setup |

## SQL

`supabase/sql/competition_international.sql`

## Nation strength (admin)

1. **Refresh selectable nations** — import GPDB nationalities, rebuild pool cache, set `active` only for squad-viable nations (**≥24 GPDB players and ≥2 GKs**). Club-depth rating bands are informational on the pool page only — they do not gate selection.
2. **Recompute seed ranks** — order active nations by **average rating of their top 100 GPDB players** (`seed_rank` 1 = strongest; fewer than 100 → average of all). Used for balanced qualifying pots; owner draft order stays on rolling owner rankings.

SQL: `supabase/sql/patches/international_refresh_selectable_and_seed_ranks.sql`

## Not in v1 (later)

- Auto qual/finals group draw
- International fixtures + matchday
- Stats apply on intl match confirm
- Best-third-place ranking job
- Knockout bracket UI
