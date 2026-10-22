-- =============================================================================
-- Result submit: both checked in → enter score; open until month lock(s)
-- =============================================================================
-- Rules (owners):
--   1) Kick-off must be agreed and BOTH clubs checked in.
--   2) No wait for kick-off minute; no 30-minute play-block cutoff for results.
--   3) Allowed while the fixture’s GPSL month is open (until that month lock),
--      and again in every later active GPSL month while the fixture stays
--      scheduled/unplayed (catch-up through subsequent locks).
-- Admins still bypass. Safe re-run.
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

  -- No calendar config → do not block
  IF NOT EXISTS (
    SELECT 1 FROM public.competition_season_calendar_config c
    WHERE c.season_id = v_fixture.season_id
  ) THEN
    RETURN true;
  END IF;

  -- Holiday-early / either-club holiday (if helpers exist)
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

  -- Same GPSL month as the fixture (open until that month’s lock)
  IF lower(btrim(v_active)) = lower(btrim(coalesce(v_fixture.gpsl_month, ''))) THEN
    RETURN true;
  END IF;

  -- Later active months while still unplayed
  IF to_regprocedure('public.competition_gpsl_month_sort(text)') IS NOT NULL THEN
    v_play_sort := public.competition_gpsl_month_sort(v_fixture.gpsl_month);
    v_active_sort := public.competition_gpsl_month_sort(v_active);
    IF v_play_sort IS NOT NULL AND v_active_sort IS NOT NULL
       AND v_active_sort > v_play_sort THEN
      RETURN true;
    END IF;
  END IF;

  -- Existing catch-up helper (grace window) as a backstop
  IF to_regprocedure('public.match_schedule_fixture_is_catch_up(bigint)') IS NOT NULL
     AND public.match_schedule_fixture_is_catch_up(p_fixture_id) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_result_month_allows_submit(bigint)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Ready to enter a result (check-in gate; no KO / 30-min block)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_schedule_assert_ready_to_play(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_home_in boolean;
  v_away_in boolean;
BEGIN
  IF public.is_gpsl_admin() THEN
    RETURN;
  END IF;

  IF to_regprocedure('public.fixture_try_checkin_forfeit(bigint)') IS NOT NULL THEN
    PERFORM public.fixture_try_checkin_forfeit(p_fixture_id);
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_fixture.status = 'played' THEN
    RAISE EXCEPTION 'This fixture has already been played';
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture is not open for result entry';
  END IF;

  -- Manual black-box (both match systems off): no KO/check-in gate
  IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
     AND public.fixture_is_manual_black_box(p_fixture_id) THEN
    RETURN;
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    RAISE EXCEPTION 'Kick-off time must be agreed before entering a result';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.home_club_short_name
  ) INTO v_home_in;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.away_club_short_name
  ) INTO v_away_in;

  IF NOT v_home_in OR NOT v_away_in THEN
    RAISE EXCEPTION 'Both clubs must check in before entering a result';
  END IF;

  -- Month lock / subsequent catch-up months
  IF NOT public.match_schedule_result_month_allows_submit(p_fixture_id) THEN
    RAISE EXCEPTION
      'Result entry is closed for this fixture until its GPSL month (or a later month) is open';
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_assert_ready_to_play(bigint)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Calendar guard on INSERT: same month rules (catch-up through later months)
-- ---------------------------------------------------------------------------
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

  IF public.match_schedule_result_month_allows_submit(p_fixture_id) THEN
    RETURN;
  END IF;

  RAISE EXCEPTION
    'Result entry is closed for this fixture until its GPSL month (or a later month) is open';
END;
$function$;

-- Prefer two-arg signature; drop bare one-arg if present (avoids ambiguity)
DROP FUNCTION IF EXISTS public.competition_assert_fixture_month_unlocked(bigint);

GRANT EXECUTE ON FUNCTION public.competition_assert_fixture_month_unlocked(bigint, text)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE 'Result submit: both checked-in → OK; open through fixture month + later active months while unplayed.';
END $$;
