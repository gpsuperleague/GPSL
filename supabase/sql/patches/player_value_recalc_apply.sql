-- =============================================================================
-- APPLY recalculated market values to ALL players (via triggers).
-- =============================================================================
-- PREREQUISITES (in order):
--   1. player_value_recalc_functions.sql
--   2. player_value_recalc_triggers.sql   ← replaces apply_calc_value()
--
-- Does NOT SET market_value directly — fires trg_player_value on each row by
-- touching Rating (no-op value change, trigger still runs).
-- trg_set_maximum_reserve_price then sets Maximum_Reserve_Price = 1.5 x MV.
-- =============================================================================

WITH touched AS (
  UPDATE public."Players" p
  SET "Rating" = p."Rating"
  WHERE public.gpsl_pv_int(p."Rating"::text) IS NOT NULL
  RETURNING
    p."Konami_ID"::text,
    p.market_value::numeric AS mv,
    p."Maximum_Reserve_Price"::numeric AS reserve
)
SELECT count(*)::integer AS rows_updated FROM touched;

NOTIFY pgrst, 'reload schema';

-- Spot-check van de Ven
SELECT
  "Konami_ID",
  "Name",
  "Rating",
  "Calc_Potential",
  market_value,
  "Maximum_Reserve_Price"
FROM public."Players"
WHERE btrim("Konami_ID"::text) = '136184';
