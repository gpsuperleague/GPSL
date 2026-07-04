-- =============================================================================
-- Exclude past mutual slots from scheduling (server-side)
-- Run after match_scheduling_phase1.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_intersection_slots(p_fixture_id bigint)
RETURNS TABLE (kickoff_at timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_cursor timestamptz;
  v_now timestamptz := now();
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT w.unlock_at, w.lock_at INTO v_unlock, v_lock
  FROM public.match_schedule_fixture_month_window(p_fixture_id) w;

  IF v_unlock IS NULL THEN
    RETURN;
  END IF;

  v_cursor := v_unlock;
  WHILE v_cursor + interval '30 minutes' <= v_lock LOOP
    IF v_cursor > v_now
       AND public.match_schedule_club_available_at(v_fixture.season_id, v_fixture.home_club_short_name, v_cursor)
       AND public.match_schedule_club_available_at(v_fixture.season_id, v_fixture.away_club_short_name, v_cursor)
    THEN
      kickoff_at := v_cursor;
      RETURN NEXT;
    END IF;
    v_cursor := v_cursor + interval '30 minutes';
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_assert_kickoff_valid(
  p_fixture_id bigint,
  p_kickoff timestamptz
)
RETURNS public.competition_fixtures
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_unlock timestamptz;
  v_lock timestamptz;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture is not open for scheduling';
  END IF;

  IF NOT public.match_schedule_kickoff_is_slot(p_kickoff) THEN
    RAISE EXCEPTION 'Kick-off must be on a 30-minute boundary (UK time)';
  END IF;

  IF p_kickoff <= now() THEN
    RAISE EXCEPTION 'That kick-off time has already passed';
  END IF;

  SELECT w.unlock_at, w.lock_at
  INTO v_unlock, v_lock
  FROM public.match_schedule_fixture_month_window(p_fixture_id) w;

  IF v_unlock IS NULL THEN
    RAISE EXCEPTION 'No GPSL month window for this fixture';
  END IF;

  IF p_kickoff < v_unlock OR p_kickoff + interval '30 minutes' > v_lock THEN
    RAISE EXCEPTION 'Kick-off must fall within the GPSL month window (% – % UK)',
      public.match_schedule_format_kickoff_uk(v_unlock),
      public.match_schedule_format_kickoff_uk(v_lock);
  END IF;

  IF NOT public.match_schedule_club_available_at(v_fixture.season_id, v_fixture.home_club_short_name, p_kickoff) THEN
    RAISE EXCEPTION 'Home club is not available at that time';
  END IF;

  IF NOT public.match_schedule_club_available_at(v_fixture.season_id, v_fixture.away_club_short_name, p_kickoff) THEN
    RAISE EXCEPTION 'Away club is not available at that time';
  END IF;

  RETURN v_fixture;
END;
$function$;

NOTIFY pgrst, 'reload schema';
