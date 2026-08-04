-- =============================================================================
-- Player career: show ALL seasons (not only current active)
--
-- Bug: competition_player_career_public live half required
--   is_current = true AND status = 'active'.
-- After End season → Summer Break (or any completed season that was never
-- archived into competition_player_season_archive), those match stats vanished
-- from the player profile — so only archived seasons (e.g. Season 1) remained.
--
-- Fix: include non-archived match stats for every season with played fixtures.
-- Archived rows still come from competition_player_season_archive.
--
-- Run in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE VIEW public.competition_player_career_public
WITH (security_invoker = false)
AS
SELECT
  a.season_id,
  a.season_label,
  a.player_id,
  p."Name" AS player_name,
  a.club_short_name,
  c."Club" AS club_name,
  a.division,
  a.player_position,
  a.stat_role,
  a.appearances,
  a.starts,
  a.goals,
  a.assists,
  a.avg_rating,
  a.potm_awards,
  a.clean_sheets,
  a.ballon_points,
  false AS is_live,
  a.archived_at AS as_of
FROM public.competition_player_season_archive a
JOIN public."Players" p ON p."Konami_ID"::text = a.player_id
JOIN public."Clubs" c ON c."ShortName" = a.club_short_name

UNION ALL

SELECT
  m.season_id,
  s.label,
  m.player_id,
  p."Name",
  m.club_short_name,
  c."Club",
  coalesce(ccs.division, ca.division),
  p."Position",
  public.competition_player_stat_role(p."Position"),
  count(*) FILTER (WHERE m.appeared)::int,
  count(*) FILTER (WHERE m.started)::int,
  coalesce(sum(m.goals), 0)::int,
  coalesce(sum(m.assists), 0)::int,
  round(avg(m.rating) FILTER (WHERE m.rating IS NOT NULL), 2),
  count(*) FILTER (WHERE m.is_player_of_match)::int,
  public.competition_player_clean_sheets(m.season_id, m.player_id, m.club_short_name, true),
  public.competition_player_ballon_points(
    count(*) FILTER (WHERE m.appeared)::int,
    coalesce(sum(m.goals), 0)::int,
    coalesce(sum(m.assists), 0)::int,
    round(avg(m.rating) FILTER (WHERE m.rating IS NOT NULL), 2),
    count(*) FILTER (WHERE m.is_player_of_match)::int,
    public.competition_player_clean_sheets(m.season_id, m.player_id, m.club_short_name, true),
    public.competition_player_stat_role(p."Position")
  ),
  true,
  now()
FROM public.competition_match_player_stats m
JOIN public.competition_fixtures f ON f.id = m.fixture_id
JOIN public.competition_seasons s ON s.id = m.season_id
JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
JOIN public."Clubs" c ON c."ShortName" = m.club_short_name
LEFT JOIN public.competition_club_seasons ccs
  ON ccs.season_id = m.season_id AND ccs.club_short_name = m.club_short_name
LEFT JOIN public.competition_club_season_archive ca
  ON ca.season_id = m.season_id AND ca.club_short_name = m.club_short_name
WHERE f.status = 'played'
  AND public.competition_fixture_counts_in_tables(f.id)
  AND NOT EXISTS (
    SELECT 1
    FROM public.competition_player_season_archive ar
    WHERE ar.season_id = m.season_id
      AND ar.player_id = m.player_id
      AND ar.club_short_name = m.club_short_name
  )
GROUP BY
  m.season_id, s.label, m.player_id, p."Name", m.club_short_name,
  c."Club", ccs.division, ca.division, p."Position";

GRANT SELECT ON public.competition_player_career_public TO authenticated;
GRANT SELECT ON public.competition_player_career_public TO anon;

NOTIFY pgrst, 'reload schema';
