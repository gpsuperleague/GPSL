-- =============================================================================
-- APPLY recalculated market values to ALL players.
-- =============================================================================
-- Run player_value_recalc_functions.sql FIRST (defines the gpsl_pv_* functions
-- and lets you preview). This script WRITES to public."Players":
--   * market_value          = recalculated Market Value (col J)
--   * Maximum_Reserve_Price  = 1.5 x market_value
--   * Calc_Potential         = recalculated Calc Value (col G)
--
-- Only players with a parseable Rating are touched. Pes Max falls back to Rating
-- when Potential is missing (same as the JS scrape fallback).
--
-- This is hard to reverse — take a DB snapshot/backup first if you want a safety net.
-- =============================================================================

BEGIN;

WITH calc AS (
  SELECT
    p."Konami_ID" AS id,
    public.gpsl_pv_int(p."Rating"::text) AS rating,
    coalesce(public.gpsl_pv_int(p."Potential"::text),
             public.gpsl_pv_int(p."Rating"::text)) AS pes_max,
    public.gpsl_pv_int(p."Age"::text) AS age,
    p."Position"::text AS position
  FROM public."Players" p
  WHERE public.gpsl_pv_int(p."Rating"::text) IS NOT NULL
)
UPDATE public."Players" p
SET
  market_value         = public.gpsl_pv_market_value(c.rating, c.pes_max, c.age, c.position),
  "Maximum_Reserve_Price" = round(public.gpsl_pv_market_value(c.rating, c.pes_max, c.age, c.position) * 1.5),
  "Calc_Potential"     = public.gpsl_pv_calc_potential(c.rating, c.pes_max, c.age)
FROM calc c
WHERE p."Konami_ID" = c.id;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Quick sanity check after applying.
SELECT count(*) AS players_with_mv,
       min(nullif(btrim(market_value::text), '')::numeric) AS min_mv,
       max(nullif(btrim(market_value::text), '')::numeric) AS max_mv,
       round(avg(nullif(btrim(market_value::text), '')::numeric)) AS avg_mv
FROM public."Players"
WHERE nullif(btrim(market_value::text), '') IS NOT NULL;
