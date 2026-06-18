-- =============================================================================
-- Cup player stats leaderboard view (current season, played cup fixtures)
-- Run once after competition_phase4_player_stats.sql / clean sheets patch.
-- =============================================================================

DROP VIEW IF EXISTS public.competition_player_cup_stats_public;

CREATE VIEW public.competition_player_cup_stats_public
WITH (security_invoker = false)
AS
SELECT
  m.season_id,
  f.cup_code,
  m.player_id,
  p."Name" AS player_name,
  m.club_short_name,
  c."Club" AS club_name,
  p."Position" AS player_position,
  public.competition_player_stat_role(p."Position") AS stat_role,
  count(*) FILTER (WHERE m.appeared)::int AS appearances,
  count(*) FILTER (WHERE m.started)::int AS starts,
  count(*) FILTER (WHERE m.subbed_on)::int AS subs,
  coalesce(sum(m.goals), 0)::int AS goals,
  coalesce(sum(m.assists), 0)::int AS assists,
  round(avg(m.rating) FILTER (WHERE m.rating IS NOT NULL), 2) AS avg_rating,
  count(*) FILTER (WHERE m.is_player_of_match)::int AS potm_awards,
  count(DISTINCT m.fixture_id) FILTER (
    WHERE m.started
      AND public.competition_player_stat_role(p."Position") IN ('goalkeeper', 'defender')
      AND public.competition_player_conceded_in_fixture(f.id, m.club_short_name) = 0
  )::int AS clean_sheets
FROM public.competition_match_player_stats m
JOIN public.competition_fixtures f ON f.id = m.fixture_id
JOIN public.competition_seasons s ON s.id = m.season_id
JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
JOIN public."Clubs" c ON c."ShortName" = m.club_short_name
WHERE s.is_current = true
  AND s.status = 'active'
  AND f.status = 'played'
  AND f.competition_type = 'cup'
  AND f.cup_code IS NOT NULL
GROUP BY
  m.season_id,
  f.cup_code,
  m.player_id,
  p."Name",
  p."Position",
  m.club_short_name,
  c."Club";

GRANT SELECT ON public.competition_player_cup_stats_public TO authenticated;
GRANT SELECT ON public.competition_player_cup_stats_public TO anon;

-- Enrich international career leaderboard with nation + club for stats page
DROP VIEW IF EXISTS public.international_player_career_public;

CREATE VIEW public.international_player_career_public
WITH (security_invoker = false)
AS
SELECT
  ipc.player_id,
  p."Name" AS player_name,
  p."Nation" AS nation,
  p."Contracted_Team" AS club_short_name,
  c."Club" AS club_name,
  ipc.caps,
  ipc.goals,
  ipc.assists,
  ipc.potm,
  CASE
    WHEN ipc.rating_count > 0 THEN round(ipc.rating_sum / ipc.rating_count, 2)
    ELSE NULL
  END AS avg_rating,
  ipc.updated_at
FROM public.international_player_career ipc
LEFT JOIN public."Players" p ON p."Konami_ID"::text = ipc.player_id
LEFT JOIN public."Clubs" c ON c."ShortName" = p."Contracted_Team";

GRANT SELECT ON public.international_player_career_public TO authenticated;
