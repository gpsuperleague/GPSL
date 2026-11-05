-- Reply overdue fine: ₿2.5m → ₿1m
-- Emergency drop: escalate play attempt (1→2, 2→3, 3 stays) then unscheduled
-- (Voluntary drop still returns to unscheduled at the same attempt.)

UPDATE public.competition_fine_tariff
SET
  amount = 1000000,
  label = 'Missed scheduling response',
  is_active = true,
  updated_at = now()
WHERE code = 'match_response_deadline'
  AND coalesce(amount, 0) <> 1000000;

CREATE OR REPLACE FUNCTION public.fixture_emergency_drop(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_club_name text;
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_opponent text;
  v_used integer;
  v_was integer;
  v_next integer;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  v_club_name := public.club_display_name(v_club);

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture not open';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    RAISE EXCEPTION 'No agreed kick-off';
  END IF;

  IF now() <= v_kickoff - interval '24 hours' THEN
    RAISE EXCEPTION 'More than 24 hours before kick-off — use voluntary drop instead';
  END IF;

  IF now() >= v_kickoff THEN
    RAISE EXCEPTION 'Kick-off has passed';
  END IF;

  v_used := public.match_schedule_emergency_drops_used(v_fixture.season_id, v_club);
  IF v_used >= 2 THEN
    RAISE EXCEPTION 'No emergency drops remaining this season';
  END IF;

  INSERT INTO public.competition_club_emergency_drop_use (
    season_id, club_short_name, fixture_id
  )
  VALUES (v_fixture.season_id, v_club, p_fixture_id);

  SELECT coalesce(s.play_attempt_count, 1) INTO v_was
  FROM public.competition_fixture_schedule s
  WHERE s.fixture_id = p_fixture_id;

  IF coalesce(v_was, 0) <= 1 THEN
    v_next := 2;
  ELSIF v_was = 2 THEN
    v_next := 3;
  ELSE
    v_next := greatest(v_was, 3);
  END IF;

  -- Bump attempt before clearing KO so open-play trigger can arm at 3.
  UPDATE public.competition_fixture_schedule
  SET
    play_attempt_count = v_next,
    updated_at = now()
  WHERE fixture_id = p_fixture_id;

  PERFORM public.match_schedule_reset_to_unscheduled(p_fixture_id);

  v_opponent := public.competition_fixture_opponent(p_fixture_id, v_club);

  PERFORM public.match_schedule_notify_opponent(
    v_fixture,
    'match_emergency_drop',
    'Emergency drop — reschedule needed',
    v_club_name
      || ' used an emergency drop (<24h). Match is unscheduled again at attempt '
      || v_next::text
      || (CASE WHEN v_next >= 3 THEN ' (open play).' ELSE '.' END),
    v_opponent,
    'emergency:' || p_fixture_id::text || ':' || v_club
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fixture_emergency_drop(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fixture_emergency_drop(bigint) TO authenticated, service_role;

COMMENT ON FUNCTION public.fixture_emergency_drop(bigint) IS
  'Emergency drop (<24h): uses season allowance, escalates play attempt 1→2→3, resets to unscheduled.';
