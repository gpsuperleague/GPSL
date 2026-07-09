# GPSL International football & World Cup (v1)

## Overview

- **60 nations** — owners manage one national team each via draft selection.
- **World Cup every 4 GPSL seasons** — finals between S4–5, S8–9, …
- **Qualifying** — 2 seasons before finals; 12×5 groups; top 2 + 8 best third → 32 finalists.
- **Finals** — 8×4 groups; top 2 → R16 → QF → SF → Final.
- **Player international stats** — cumulative caps, goals, assists, POTM, average rating (`international_player_career`).

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

1. **Refresh selectable nations** — import GPDB nationalities, rebuild pool cache, set `active` only for squad-viable nations (≥24 players, ≥2 GKs, club depth bands).
2. **Recompute seed ranks from pool** — order active nations by weighted rating-band totals (`seed_rank` 1 = strongest). Used for balanced qualifying pots; owner draft order stays on rolling owner rankings.

SQL: `supabase/sql/patches/international_refresh_selectable_and_seed_ranks.sql`

## Not in v1 (later)

- Auto qual/finals group draw
- International fixtures + matchday
- Stats apply on intl match confirm
- Best-third-place ranking job
- Knockout bracket UI
