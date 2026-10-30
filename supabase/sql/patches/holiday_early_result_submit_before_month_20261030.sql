-- =============================================================================
-- Holiday early: allow result submit before the fixture GPSL month
-- (2026-10-30)
--
-- Bug: Match Day blocked score entry for November fixtures played early while
-- the active month is still earlier (e.g. Sep/Oct). Server month gate and/or
-- fixtures_public missing is_holiday_early left owners stuck after both
-- checked in.
--
-- Fix:
--   1) match_schedule_result_month_allows_submit — holiday-early OR
--      holiday-impacted while active month is still before the fixture month
--   2) competition_assert_fixture_month_unlocked — same corridor
--   3) competition_fixtures_public — expose is_holiday_early for the UI
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_result_month_allows_submit(
  p_fixture_id bigint
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_active text;
  v_play_sort int;
  v_active_sort int;
BEGIN
  SELECT f.* INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND OR v_fixture.status IS DISTINCT FROM 'scheduled' THEN
    RETURN false;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_season_calendar_config c
    WHERE c.season_id = v_fixture.season_id
  ) THEN
    RETURN true;
  END IF;

  -- Live holiday-early helper (either club)
  IF to_regprocedure('public.match_schedule_fixture_is_holiday_early(bigint)') IS NOT NULL
     AND public.match_schedule_fixture_is_holiday_early(p_fixture_id) THEN
    RETURN true;
  END IF;

  v_active := NULL;
  IF to_regprocedure('public.competition_active_gpsl_month(bigint,timestamptz)') IS NOT NULL THEN
    v_active := public.competition_active_gpsl_month(v_fixture.season_id, now());
  END IF;

  IF v_active IS NULL OR btrim(v_active) = '' THEN
    RETURN false;
  END IF;

  -- Same GPSL month as the fixture
  IF lower(btrim(v_active)) = lower(btrim(coalesce(v_fixture.gpsl_month, ''))) THEN
    RETURN true;
  END IF;

  v_play_sort := NULL;
  v_active_sort := NULL;
  IF to_regprocedure('public.competition_gpsl_month_sort(text)') IS NOT NULL THEN
    v_play_sort := public.competition_gpsl_month_sort(v_fixture.gpsl_month);
    v_active_sort := public.competition_gpsl_month_sort(v_active);
  END IF;

  -- Later active months (catch-up)
  IF v_play_sort IS NOT NULL AND v_active_sort IS NOT NULL
     AND v_active_sort > v_play_sort THEN
    RETURN true;
  END IF;

  -- Holiday corridor: still before the fixture month (play-early).
  -- Uses impacted (booking overlap) so result entry stays open even if the
  -- holiday window has already ended after they played early.
  IF v_play_sort IS NOT NULL AND v_active_sort IS NOT NULL
     AND v_active_sort < v_play_sort
     AND to_regprocedure('public.match_schedule_fixture_is_holiday_impacted(bigint)') IS NOT NULL
     AND public.match_schedule_fixture_is_holiday_impacted(p_fixture_id) THEN
    RETURN true;
  END IF;

  IF to_regprocedure('public.match_schedule_fixture_is_catch_up(bigint)') IS NOT NULL
     AND public.match_schedule_fixture_is_catch_up(p_fixture_id) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_result_month_allows_submit(bigint)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.match_schedule_result_month_allows_submit(bigint) IS
  'Result entry month gate: fixture month, later catch-up, holiday-early, or holiday-impacted before fixture month.';

CREATE OR REPLACE FUNCTION public.competition_assert_fixture_month_unlocked(
  p_fixture_id bigint,
  p_club_short_name text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_club text;
BEGIN
  IF public.is_gpsl_admin() THEN
    RETURN;
  END IF;

  v_club := nullif(btrim(coalesce(p_club_short_name, '')), '');

  IF to_regprocedure('public.match_schedule_fixture_is_holiday_early(bigint)') IS NOT NULL
     AND public.match_schedule_fixture_is_holiday_early(p_fixture_id) THEN
    IF to_regprocedure('public.match_schedule_assert_holiday_early_squad_ready(bigint)') IS NOT NULL THEN
      PERFORM public.match_schedule_assert_holiday_early_squad_ready(p_fixture_id);
    END IF;
    RETURN;
  END IF;

  -- Same month / catch-up / holiday corridor before fixture month
  IF public.match_schedule_result_month_allows_submit(p_fixture_id) THEN
    RETURN;
  END IF;

  IF v_club IS NOT NULL
     AND to_regprocedure('public.club_holiday_allows_fixture_early(bigint,text)') IS NOT NULL
     AND public.club_holiday_allows_fixture_early(p_fixture_id, v_club) THEN
    RETURN;
  END IF;

  SELECT f.* INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_season_calendar_config c
    WHERE c.season_id = v_fixture.season_id
  ) THEN
    RETURN;
  END IF;

  RAISE EXCEPTION
    'Result entry is closed for this fixture until its GPSL month (or a later month) is open';
END;
$function$;

DROP FUNCTION IF EXISTS public.competition_assert_fixture_month_unlocked(bigint);

GRANT EXECUTE ON FUNCTION public.competition_assert_fixture_month_unlocked(bigint, text)
  TO authenticated, service_role;

-- Expose is_holiday_early on fixtures_public (Match Day / Fixtures UI)
DROP VIEW IF EXISTS public.competition_fixtures_public;

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
  public.match_schedule_fixture_is_holiday_early(f.id) AS is_holiday_early,
  (
    f.admin_replay_reset_at IS NOT NULL
    AND f.status = 'scheduled'
  ) AS is_admin_replay,
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

SELECT
  to_regprocedure('public.match_schedule_result_month_allows_submit(bigint)') IS NOT NULL
    AS month_gate_fn,
  position(
    'match_schedule_fixture_is_holiday_impacted'
    IN pg_get_functiondef('public.match_schedule_result_month_allows_submit(bigint)'::regprocedure)
  ) > 0 AS allows_holiday_corridor_before_month;
