-- =============================================================================
-- APPLY recalculated market values to ALL players.
-- =============================================================================
-- PREREQUISITE: run player_value_recalc_functions.sql in the SAME Supabase project
-- (creates gpsl_pv_* functions + gpsl_player_value_recalc_apply()).
--
-- WRITES to public."Players":
--   * market_value            = recalculated Market Value (col J)
--   * Maximum_Reserve_Price   = 1.5 x market_value
--   * Calc_Potential          = recalculated Calc Value (col G)
--
-- GPDB and squad read the same Players table — no separate GPDB step.
--
-- IMPORTANT (Supabase SQL editor):
--   * Run this ENTIRE file in one go (do not highlight only the last SELECT).
--   * Avoid BEGIN/COMMIT — the apply function is a single atomic statement.
--   * Check the JSON result: rows_updated must be > 0 (typically ~all players).
--
-- Take a DB snapshot first if you want a safety net.
-- =============================================================================

-- 1) Apply (returns row counts — must see rows_updated > 0)
SELECT public.gpsl_player_value_recalc_apply() AS apply_result;

-- 2) Sanity check — avg MV should jump well above legacy ~₿10M band for 79-rated players
SELECT
  count(*) AS players_with_mv,
  min(nullif(btrim(market_value::text), '')::numeric) AS min_mv,
  max(nullif(btrim(market_value::text), '')::numeric) AS max_mv,
  round(avg(nullif(btrim(market_value::text), '')::numeric)) AS avg_mv
FROM public."Players"
WHERE nullif(btrim(market_value::text), '') IS NOT NULL;

-- 3) Spot-check a 79-rated CB age 24 (adjust name if needed)
SELECT
  "Konami_ID",
  "Name",
  "Rating",
  "Potential",
  "Calc_Potential",
  "Age",
  "Position",
  market_value,
  "Maximum_Reserve_Price",
  public.gpsl_pv_market_value(
    public.gpsl_pv_int("Rating"::text),
    coalesce(public.gpsl_pv_int("Potential"::text), public.gpsl_pv_int("Rating"::text)),
    public.gpsl_pv_int("Age"::text),
    "Position"::text
  ) AS formula_mv_should_match
FROM public."Players"
WHERE "Rating"::text ~ '^79'
  AND public.gpsl_pv_int("Age"::text) = 24
  AND upper(btrim("Position"::text)) = 'CB'
ORDER BY "Name"
LIMIT 5;

NOTIFY pgrst, 'reload schema';
