# PESDB player values — spreadsheet formulas → GPSL

**Bulk CSV import / migration is deferred** (too risky without a formal backup flow). The formulas and columns are wired for **display** in GPDB and squad; stored `market_value` in the database is unchanged until you choose to update it.

Source: league Excel (columns match `Current GPDB.csv`).

## Column mapping

| Excel | PESDB scrape CSV | Supabase `Players` |
|-------|------------------|-------------------|
| Rating (E) | `rating` | `Rating` |
| Pes Max (F) | `max_level_rating` | store as raw pes ceiling (optional column or overwrite `Potential`) |
| Calc Value (G) | *(computed)* | `Calc_Potential` or effective potential used for MV |
| Age (D) | `age` | `Age` |
| Position (B) | `Position` | `Position` |
| Playstyle (H) | `playing_style` | `Playstyle` |
| Market Value (J) | *(computed)* | `market_value` |
| Maximum Release Fee (I) | *(computed)* | `Maximum_Reserve_Price` = **1.5 × market_value** |

**Potential (game sense):** scrape `max_level_rating` = Pes Max. **Calc Value** bumps it when Pes Max = current Rating (pesdb often lists no growth). **Market value** uses **Calc Value (G)**, not raw Pes Max.

## G2 — Calc Value (calculated potential)

```excel
=LET(
    rating, $E2,
    base,   $F2,
    age,    $D2,
    bonus,  LOOKUP(rating,
              {0,61,62,63,69,73,74,76,78,79},
              {17,18,17,16,15,14,13,12,11,11}),
    ageBonus, IF(age<=19,2,0),
    IF(rating=base, base + bonus + ageBonus, base)
)
```

**Logic:** If current rating equals Pes Max, potential = Pes Max + tier bonus (from rating) + 2 for age ≤ 19. Otherwise potential = Pes Max (card already “boosted” on site).

## J2 — Market Value

```excel
=LET(
  baseValue, XLOOKUP(E2, $X$2:$X$29, $Y$2:$Y$29, 0),
  valueCalc,
    baseValue +
    (baseValue * XLOOKUP(G2, $Z$2:$Z$22, $AA$2:$AA$22, 0)) +
    (baseValue * XLOOKUP(D2, $AB$2:$AB$26, $AC$2:$AC$26, 0)) +
    (baseValue * IF(ISNUMBER(MATCH(D2, $AD$2:$AD$5, 0)), XLOOKUP(D2, $AD$2:$AD$5, $AE$2:$AE$5, 0), 0)) +
    (baseValue * XLOOKUP(B2, $AF$2:$AF$14, $AG$2:$AG$14, 0)),
  IF(D2<30, MAX(5000000, valueCalc), MAX(2000000, valueCalc))
)
```

**Logic:** Start from base value by **current Rating**, add % adjustments from **Calc Value**, **Age**, optional **young star** ages (16–19), and **Position**. Floor ₿5M if age &lt; 30, else ₿2M.

## GPSL extension: base value for ratings 60–64

Your Excel **X** column does not list every rating 60–64. `XLOOKUP(..., 0)` returns **0** for those rows, so market value often collapses to the **₿5M floor** only.

**GPSL keeps the same J2 formula** but uses `getBaseValueByRating()` from `player_value_calcs.js`:

| Rating | Excel (typical) | GPSL extended base |
|--------|-----------------|-------------------|
| 60–64 | 0 → floor ₿5M | ₿2.5M–₿4.5M stepped toward 70 |
| 65+ | values from sheet | same knots, filled 65–93 between anchors |

- **G2 (Calc Potential)** — unchanged (still your LOOKUP + age bonus).
- **Potential / Age / Position %** — same tables as Excel (`XLOOKUP` exact; potential % also interpolates between rows if Calc Value is between keys).
- **Maximum reserve** — still **1.5 × market_value**.

The extended bases are in `data/player_value_tables.json` under `baseValueByRating` and `baseValuePolicy`. They do **not** modify your `.xlsx`; only the site import path.

## Current setup (live now)

1. Run once: [`supabase/sql/players_economics_columns.sql`](../supabase/sql/players_economics_columns.sql) — adds `Potential`, `Calc_Potential` (nullable).
2. Code: `player_value_calcs.js`, `player_economics.js`, `data/player_value_tables.json`.
3. **GPDB / squad:** Rating shown as **85 (95)** (current + calc potential). **Pot.** column = calc potential. **Market value** column still shows **stored** DB values.
4. `computedEconomicsForPlayer()` in `player_economics.js` returns what MV would be from formulas (for future admin tools); it does not write to the DB.

## Migration (admin sync)

1. Run [`supabase/sql/patches/gpdb_pesdb_sync.sql`](../supabase/sql/patches/gpdb_pesdb_sync.sql).
2. Deploy edge function `gpdb-pesdb-scrape` (see `scripts/README_pesdb_sync.md`).
3. **Admin → Season Break → Data tools → GPDB PESDB sync** — scrape in-browser, preview, apply.
4. Optional: **GPDB deduplication** after sync.

Legacy cards (`pesdb_unavailable`) stay at their club, cannot be sold, renew **1 season** at a time. Admin can restore manually or clear on next sync when the card reappears on pesdb.net.
