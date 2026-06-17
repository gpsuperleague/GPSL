-- =============================================================================
-- DIAGNOSE player value recalc — run BEFORE/AFTER apply (read-only).
-- =============================================================================

-- A) Are the functions installed?
SELECT proname
FROM pg_proc
WHERE proname LIKE 'gpsl_pv_%' OR proname = 'gpsl_player_value_recalc_apply'
ORDER BY proname;

-- B) Formula smoke test (79 CB age 24, pes max = rating → calc 90 → MV ~₿42.4M)
SELECT public.gpsl_pv_market_value(79, 79, 24, 'CB') AS expected_mv_79_cb_24;

-- C) Preview top deltas (same as functions file — no writes)
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
WHERE abs(coalesce(new_mv, 0) - coalesce(current_mv, 0)) > 100000
ORDER BY abs(coalesce(new_mv, 0) - coalesce(current_mv, 0)) DESC
LIMIT 20;

-- D) Single player lookup (edit name)
SELECT
  "Konami_ID",
  "Name",
  "Rating",
  "Potential",
  "Calc_Potential",
  "Age",
  "Position",
  market_value AS stored_mv,
  "Maximum_Reserve_Price",
  public.gpsl_pv_calc_potential(
    public.gpsl_pv_int("Rating"::text),
    coalesce(public.gpsl_pv_int("Potential"::text), public.gpsl_pv_int("Rating"::text)),
    public.gpsl_pv_int("Age"::text)
  ) AS formula_calc,
  public.gpsl_pv_market_value(
    public.gpsl_pv_int("Rating"::text),
    coalesce(public.gpsl_pv_int("Potential"::text), public.gpsl_pv_int("Rating"::text)),
    public.gpsl_pv_int("Age"::text),
    "Position"::text
  ) AS formula_mv
FROM public."Players"
WHERE "Name" ILIKE '%van de Ven%';

-- E) Would Konami_ID join match? (should be 0 rows if join is broken)
SELECT count(*) AS join_mismatch_count
FROM public."Players" p
LEFT JOIN (
  SELECT p2."Konami_ID"::text AS konami_id
  FROM public."Players" p2
  WHERE public.gpsl_pv_int(p2."Rating"::text) IS NOT NULL
) c ON p."Konami_ID"::text = c.konami_id
WHERE public.gpsl_pv_int(p."Rating"::text) IS NOT NULL
  AND c.konami_id IS NULL;
