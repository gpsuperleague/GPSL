-- =============================================================================
-- League stats: goalkeeper clean sheets on competition_player_season_stats_public
-- Requires: competition_history.sql (competition_player_clean_sheets, stat_role)
-- Run once in Supabase SQL Editor after prior competition scripts.
--
-- DROP required: Postgres cannot REPLACE a view when new columns are inserted
-- before existing ones (42P16 "cannot change name of view column").
-- =============================================================================

DROP VIEW IF EXISTS public.competition_player_season_stats_public;

CREATE VIEW public.competition_player_season_stats_public
WITH (security_invoker = false)
AS
SELECT
  m.season_id,
  m.player_id,
  p."Name" AS player_name,
  m.club_short_name,
  c."Club" AS club_name,
  ccs.division,
  p."Position" AS player_position,
  public.competition_player_stat_role(p."Position") AS stat_role,
  count(*) FILTER (WHERE m.appeared)::int AS appearances,
  count(*) FILTER (WHERE m.started)::int AS starts,
  count(*) FILTER (WHERE m.subbed_on)::int AS subs,
  coalesce(sum(m.goals), 0)::int AS goals,
  coalesce(sum(m.assists), 0)::int AS assists,
  round(avg(m.rating) FILTER (WHERE m.rating IS NOT NULL), 2) AS avg_rating,
  count(*) FILTER (WHERE m.is_player_of_match)::int AS potm_awards,
  public.competition_player_clean_sheets(
    m.season_id,
    m.player_id,
    m.club_short_name,
    false
  ) AS clean_sheets
FROM public.competition_match_player_stats m
JOIN public.competition_fixtures f ON f.id = m.fixture_id
JOIN public.competition_seasons s ON s.id = m.season_id
JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
JOIN public."Clubs" c ON c."ShortName" = m.club_short_name
LEFT JOIN public.competition_club_seasons ccs
  ON ccs.season_id = m.season_id AND ccs.club_short_name = m.club_short_name
WHERE s.is_current = true
  AND s.status = 'active'
  AND f.status = 'played'
  AND f.competition_type = 'league'
GROUP BY
  m.season_id,
  m.player_id,
  p."Name",
  p."Position",
  m.club_short_name,
  c."Club",
  ccs.division;

GRANT SELECT ON public.competition_player_season_stats_public TO authenticated;
GRANT SELECT ON public.competition_player_season_stats_public TO anon;
