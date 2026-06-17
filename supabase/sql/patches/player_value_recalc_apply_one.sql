-- =============================================================================
-- Single-player MV recalc — fire trigger (not direct SET).
-- =============================================================================
-- Prerequisites: player_value_recalc_functions.sql + player_value_recalc_triggers.sql
-- Expect: market_value = 42412500, Maximum_Reserve_Price = 63618750
-- =============================================================================

UPDATE public."Players" p
SET "Rating" = p."Rating"
WHERE btrim(p."Konami_ID"::text) = '136184'
RETURNING
  "Konami_ID",
  "Name",
  "Rating",
  "Calc_Potential",
  market_value,
  "Maximum_Reserve_Price";
