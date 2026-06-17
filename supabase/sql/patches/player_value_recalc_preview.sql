-- =============================================================================
-- PREVIEW recalculated market values (READ-ONLY — can be slow / timeout in UI).
-- Run AFTER player_value_recalc_functions.sql.
-- Limited to top 50 deltas so Supabase SQL editor does not time out.
-- =============================================================================

WITH calc AS (
  SELECT
    p."Konami_ID",
    p."Name",
    public.gpsl_pv_int(p."Rating"::text) AS rating,
    public.gpsl_pv_int(p."Potential"::text) AS potential,
    public.gpsl_pv_int(p."Age"::text) AS age,
    btrim(p."Position"::text) AS position,
    nullif(btrim(p.market_value::text), '')::numeric AS current_mv,
    public.gpsl_pv_market_value(
      public.gpsl_pv_int(p."Rating"::text),
      coalesce(public.gpsl_pv_int(p."Potential"::text), public.gpsl_pv_int(p."Rating"::text)),
      public.gpsl_pv_int(p."Age"::text),
      p."Position"::text
    ) AS new_mv
  FROM public."Players" p
  WHERE public.gpsl_pv_int(p."Rating"::text) IS NOT NULL
)
SELECT
  "Konami_ID", "Name", rating, potential, age, position,
  current_mv, new_mv, (new_mv - current_mv) AS delta
FROM calc
ORDER BY abs(coalesce(new_mv, 0) - coalesce(current_mv, 0)) DESC
LIMIT 50;
