-- =============================================================================
-- Expose manual_black_box on competition_fixtures_public (both clubs GPSL OFF)
-- Safe re-run.
-- =============================================================================

DROP VIEW IF EXISTS public.competition_fixtures_public;

-- security_invoker=false: schedule/check-in RLS is club/admin-only; the public
-- fixtures board must still show kick-off status to every owner (read-only).
CREATE VIEW public.competition_fixtures_public
WITH (security_invoker = false)
AS
SELECT
  f.id,
  f.season_id,
  f.division,
  f.competition_type,
  f.cup_code,
  f.cup_round,
  f.cup_match,
  f.cup_leg,
  f.matchday,
  f.gpsl_month,
  f.week_in_month,
  f.home_club_short_name,
  hc."Club" AS home_club_name,
  f.away_club_short_name,
  ac."Club" AS away_club_name,
  f.weather,
  f.pitch_condition,
  f.kit_season,
  public.competition_club_continent(f.home_club_short_name) AS home_continent,
  f.venue_name,
  f.venue_capacity,
  f.home_goals,
  f.away_goals,
  f.status,
  f.is_forfeit,
  public.match_schedule_fixture_is_catch_up(f.id) AS is_catch_up,
  sub.submission_id,
  sub.submission_status,
  sub.submitted_by_club,
  sub.proposed_home_goals,
  sub.proposed_away_goals,
  sub.proposed_et_home_goals,
  sub.proposed_et_away_goals,
  sub.proposed_pen_winner_club,
  COALESCE(sch.status, 'unscheduled'::text) AS schedule_status,
  sch.agreed_kickoff_at,
  sch.pending_proposal_id AS schedule_pending_proposal_id,
  sch.home_proposal_count AS schedule_home_proposal_count,
  sch.away_proposal_count AS schedule_away_proposal_count,
  COALESCE(sch.discord_hint_shown, false) AS schedule_discord_hint,
  sch.response_due_at AS schedule_response_due_at,
  sch.response_required_club_short_name AS schedule_response_required_club,
  chk.home_checked_in,
  chk.away_checked_in,
  public.fixture_is_manual_black_box(f.id) AS manual_black_box
FROM public.competition_fixtures f
JOIN public.competition_seasons s ON s.id = f.season_id
JOIN public."Clubs" hc ON hc."ShortName" = f.home_club_short_name
JOIN public."Clubs" ac ON ac."ShortName" = f.away_club_short_name
LEFT JOIN public.competition_fixture_schedule sch ON sch.fixture_id = f.id
LEFT JOIN LATERAL (
  SELECT
    EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = f.id AND c.club_short_name = f.home_club_short_name
    ) AS home_checked_in,
    EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = f.id AND c.club_short_name = f.away_club_short_name
    ) AS away_checked_in
) chk ON true
LEFT JOIN LATERAL (
  SELECT
    rs.id AS submission_id,
    rs.status AS submission_status,
    rs.submitted_by_club,
    rs.home_goals AS proposed_home_goals,
    rs.away_goals AS proposed_away_goals,
    rs.et_home_goals AS proposed_et_home_goals,
    rs.et_away_goals AS proposed_et_away_goals,
    rs.pen_winner_club_short_name AS proposed_pen_winner_club
  FROM public.competition_result_submissions rs
  WHERE rs.fixture_id = f.id
    AND rs.status = 'pending'::text
    AND (
      public.is_gpsl_admin()
      OR public.my_club_shortname() = f.home_club_short_name
      OR public.my_club_shortname() = f.away_club_short_name
    )
  LIMIT 1
) sub ON true
WHERE s.status = 'active'::text
  AND s.is_current = true;

REVOKE ALL ON public.competition_fixtures_public FROM PUBLIC;
REVOKE ALL ON public.competition_fixtures_public FROM anon, authenticated;
GRANT SELECT ON public.competition_fixtures_public TO authenticated;
GRANT SELECT ON public.competition_fixtures_public TO anon;

NOTIFY pgrst, 'reload schema';
