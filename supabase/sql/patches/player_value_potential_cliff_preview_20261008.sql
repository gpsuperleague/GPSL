-- =============================================================================
-- PREVIEW ONLY (no writes): market values after the Calc Potential cliff fix
-- =============================================================================
-- Calc Potential today: rating = PES max -> rating + tier bonus (+2 if <=19);
-- otherwise PES max. A player 1 point below a low max (e.g. 77 / 78) gets
-- potential 78 -> -75%, while a maxed 77 / 77 gets 89 -> +7.5%.
-- Fix: Calc Potential = greatest(PES max, rating + tier bonus + young bonus),
-- so headroom never makes a player worth less than being maxed out.
--
-- Lists every player whose value would change (Gnabry first), biggest rises
-- first, with totals in every row.
-- =============================================================================

WITH src AS (
  SELECT
    p."Konami_ID"::text AS kid,
    p."Name"::text AS name,
    public.gpsl_pv_int(p."Rating"::text) AS rating,
    coalesce(public.gpsl_pv_int(p."Potential"::text), public.gpsl_pv_int(p."Rating"::text)) AS pes_max,
    public.gpsl_pv_int(p."Age"::text) AS age,
    p."Position"::text AS pos,
    nullif(btrim(p.market_value::text), '')::numeric AS old_mv
  FROM public."Players" p
  WHERE public.gpsl_pv_int(p."Rating"::text) IS NOT NULL
),
calc AS (
  SELECT
    s.*,
    greatest(
      s.pes_max,
      s.rating + public.gpsl_pv_rating_bonus(s.rating) + CASE WHEN coalesce(s.age, 99) <= 19 THEN 2 ELSE 0 END
    ) AS new_calc
  FROM src s
),
mv AS (
  SELECT
    c.*,
    public.gpsl_pv_apply_stored_boosts(
      GREATEST(
        CASE WHEN coalesce(c.age, 0) < 30 THEN 5000000 ELSE 2000000 END,
        round(
          b.base
          + b.base * public.gpsl_pv_potential_pct(c.new_calc)
          + b.base * public.gpsl_pv_age_pct(c.age)
          + b.base * public.gpsl_pv_youngstar_pct(c.age)
          + b.base * public.gpsl_pv_position_pct(c.pos)
        )
      ),
      c.kid
    ) AS new_mv
  FROM calc c
  CROSS JOIN LATERAL (SELECT public.gpsl_pv_base_value(c.rating) AS base) b
)
SELECT
  name, rating, pes_max, age, pos,
  old_mv, new_mv, new_mv - coalesce(old_mv, 0) AS change,
  count(*) OVER () AS players_changing,
  sum(new_mv - coalesce(old_mv, 0)) OVER () AS total_mv_added
FROM mv
WHERE new_mv IS DISTINCT FROM old_mv
ORDER BY (name ILIKE '%gnabry%') DESC, new_mv - coalesce(old_mv, 0) DESC
LIMIT 200;
