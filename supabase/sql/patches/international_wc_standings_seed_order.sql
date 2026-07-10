-- =============================================================================
-- Qual/finals standings: include seed_rank; order by table then seed
-- (At 0 points, groups show strongest seed at the top.)
-- Safe re-run.
-- =============================================================================

DROP VIEW IF EXISTS public.international_qual_standings_public;
CREATE VIEW public.international_qual_standings_public
WITH (security_invoker = false)
AS
SELECT
  wc.cycle_no,
  wc.label AS cycle_label,
  g.group_code,
  m.nation_code,
  n.name AS nation_name,
  n.flag_emoji,
  n.seed_rank,
  m.played,
  m.won,
  m.drawn,
  m.lost,
  m.goals_for,
  m.goals_against,
  m.goals_for - m.goals_against AS goal_diff,
  m.points,
  m.third_place_rank,
  m.qualified
FROM public.international_qual_group_members m
JOIN public.international_qual_groups g ON g.id = m.group_id
JOIN public.international_wc_cycles wc ON wc.id = g.cycle_id
JOIN public.international_nations n ON n.code = m.nation_code
ORDER BY
  wc.cycle_no,
  g.group_code,
  m.points DESC,
  (m.goals_for - m.goals_against) DESC,
  m.goals_for DESC,
  n.seed_rank ASC NULLS LAST,
  m.nation_code;

DROP VIEW IF EXISTS public.international_finals_standings_public;
CREATE VIEW public.international_finals_standings_public
WITH (security_invoker = false)
AS
SELECT
  wc.cycle_no,
  wc.label AS cycle_label,
  g.group_code,
  m.nation_code,
  n.name AS nation_name,
  n.flag_emoji,
  n.seed_rank,
  m.played,
  m.won,
  m.drawn,
  m.lost,
  m.goals_for,
  m.goals_against,
  m.goals_for - m.goals_against AS goal_diff,
  m.points,
  m.qualified_knockout
FROM public.international_finals_group_members m
JOIN public.international_finals_groups g ON g.id = m.group_id
JOIN public.international_wc_cycles wc ON wc.id = g.cycle_id
JOIN public.international_nations n ON n.code = m.nation_code
ORDER BY
  wc.cycle_no,
  g.group_code,
  m.points DESC,
  (m.goals_for - m.goals_against) DESC,
  m.goals_for DESC,
  n.seed_rank ASC NULLS LAST,
  m.nation_code;

GRANT SELECT ON public.international_qual_standings_public TO authenticated;
GRANT SELECT ON public.international_finals_standings_public TO authenticated;

NOTIFY pgrst, 'reload schema';
