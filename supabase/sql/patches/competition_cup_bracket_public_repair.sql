-- =============================================================================
-- Restore competition_cup_bracket_public (cup_leg + schedule columns)
-- Run if cups.html 400s on order=cup_leg — caused by match_scheduling_phase1/2
-- recreating a stripped-down bracket view.
-- =============================================================================

DROP VIEW IF EXISTS public.competition_cup_qualified_public;
DROP VIEW IF EXISTS public.competition_cup_bracket_public;

CREATE VIEW public.competition_cup_bracket_public
WITH (security_invoker = false)
AS
SELECT
  n.id,
  n.season_id,
  n.cup_code,
  n.round_no,
  n.match_no,
  n.cup_leg,
  n.leg1_node_id,
  sch.round_label,
  sch.gpsl_month AS round_gpsl_month,
  n.home_club_short_name,
  hc."Club" AS home_club_name,
  n.away_club_short_name,
  ac."Club" AS away_club_name,
  n.winner_club_short_name,
  wc."Club" AS winner_club_name,
  n.fixture_id,
  f.status AS fixture_status,
  f.home_goals,
  f.away_goals,
  f.gpsl_month AS fixture_gpsl_month,
  f.weather,
  f.pitch_condition,
  f.kit_season,
  public.competition_club_continent(n.home_club_short_name) AS home_continent,
  n.child_node_id,
  n.child_slot
FROM public.competition_cup_bracket_nodes n
JOIN public.competition_seasons s ON s.id = n.season_id
LEFT JOIN public.competition_cup_round_schedule sch
  ON sch.cup_code = n.cup_code
 AND sch.round_no = n.round_no
 AND sch.cup_leg = coalesce(n.cup_leg, 1)
LEFT JOIN public."Clubs" hc ON hc."ShortName" = n.home_club_short_name
LEFT JOIN public."Clubs" ac ON ac."ShortName" = n.away_club_short_name
LEFT JOIN public."Clubs" wc ON wc."ShortName" = n.winner_club_short_name
LEFT JOIN public.competition_fixtures f ON f.id = n.fixture_id
WHERE s.status = 'active' AND s.is_current = true;

CREATE VIEW public.competition_cup_qualified_public
WITH (security_invoker = false)
AS
SELECT
  s.id AS season_id,
  cup.cup_code,
  q.club_short_name
FROM public.competition_seasons s
CROSS JOIN (
  VALUES ('super8'), ('plate'), ('shield'), ('spoon'), ('league_cup')
) AS cup(cup_code)
CROSS JOIN LATERAL unnest(public.competition_qualify_cup_clubs(s.id, cup.cup_code)) AS q(club_short_name)
WHERE s.is_current = true AND s.status = 'active';

GRANT SELECT ON public.competition_cup_bracket_public TO authenticated;
GRANT SELECT ON public.competition_cup_bracket_public TO anon;
GRANT SELECT ON public.competition_cup_qualified_public TO authenticated;

NOTIFY pgrst, 'reload schema';
