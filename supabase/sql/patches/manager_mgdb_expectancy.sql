-- Extend MGDB public view with manager expectancy (contract targets + impact chart).
-- Run after managers_system.sql and manager_squad_boost_impact.sql. Safe to re-run.

DROP VIEW IF EXISTS public.managers_gpdb_public;

CREATE VIEW public.managers_gpdb_public
WITH (security_invoker = true)
AS
SELECT
  m.id,
  m.slug,
  m.name,
  m.nation,
  m.possession,
  m.quick_counter,
  m.long_ball_counter,
  m.out_wide,
  m.long_ball,
  m.age,
  m.rating,
  m.market_value,
  m.contracted_club,
  m.contract_seasons_remaining,
  m.weekly_wage,
  CASE
    WHEN m.contracted_club IS NULL OR btrim(m.contracted_club) = '' THEN 'FREE AGENT'
    ELSE m.contracted_club
  END AS contracted_display,
  public.manager_boost_band_label(1, e.boost1_min, e.boost1_max) AS boost1_label,
  public.manager_boost_band_label(2, e.boost2_min, e.boost2_max) AS boost2_label,
  public.manager_boost_band_label(3, e.boost3_min, e.boost3_max) AS boost3_label,
  (SELECT tf.label FROM public.manager_target_for(m.rating, 'superleague') tf) AS target_superleague,
  (SELECT tf.label FROM public.manager_target_for(m.rating, 'championship_a') tf) AS target_championship_a,
  (SELECT tf.label FROM public.manager_target_for(m.rating, 'championship_b') tf) AS target_championship_b
FROM public."Managers" m
LEFT JOIN public.manager_proficiency_expectancy e
  ON e.proficiency = public.manager_proficiency_clamp(m.rating);

GRANT SELECT ON public.managers_gpdb_public TO authenticated;
GRANT SELECT ON public.managers_gpdb_public TO anon;

NOTIFY pgrst, 'reload schema';
