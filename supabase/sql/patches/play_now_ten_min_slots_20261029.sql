-- =============================================================================
-- Play now only: allow UK 10-minute kick-off intervals (not 30-minute).
-- Check-in (±10 min) and 30-minute play block stay unchanged — they follow
-- whatever agreed_kickoff_at is set after both confirm.
--
-- Normal propose / Discord lock / mutual new-time stay on 30-minute slots.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_kickoff_is_ten_min_slot(p_kickoff timestamptz)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    p_kickoff IS NOT NULL
    AND EXTRACT(MINUTE FROM p_kickoff AT TIME ZONE 'Europe/London')::integer % 10 = 0
    AND EXTRACT(SECOND FROM p_kickoff AT TIME ZONE 'Europe/London')::integer = 0;
$$;

COMMENT ON FUNCTION public.match_schedule_kickoff_is_ten_min_slot(timestamptz) IS
  'True when kick-off sits on a UK 10-minute boundary (Play now only).';

CREATE OR REPLACE FUNCTION public.match_schedule_current_uk_ten_min_slot()
RETURNS timestamptz
LANGUAGE sql
STABLE
AS $$
  SELECT (
    date_trunc('hour', local_ts)
    + (floor(extract(minute FROM local_ts) / 10)::int * interval '10 minutes')
  ) AT TIME ZONE 'Europe/London'
  FROM (SELECT now() AT TIME ZONE 'Europe/London' AS local_ts) t;
$$;

GRANT EXECUTE ON FUNCTION public.match_schedule_kickoff_is_ten_min_slot(timestamptz)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.match_schedule_current_uk_ten_min_slot()
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.match_schedule_assert_play_now_kickoff_ok(
  p_fixture_id bigint,
  p_kickoff timestamptz
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_schedule public.competition_fixture_schedule;
BEGIN
  SELECT * INTO v_schedule
  FROM public.competition_fixture_schedule
  WHERE fixture_id = p_fixture_id;

  IF NOT FOUND OR v_schedule.status <> 'agreed' OR v_schedule.agreed_kickoff_at IS NULL THEN
    RAISE EXCEPTION 'Fixture does not have an agreed kick-off';
  END IF;

  IF now() >= v_schedule.agreed_kickoff_at THEN
    RAISE EXCEPTION 'Play now is only available before the agreed kick-off';
  END IF;

  IF p_kickoff IS NULL THEN
    RAISE EXCEPTION 'Play-now kick-off is required';
  END IF;

  IF NOT public.match_schedule_kickoff_is_ten_min_slot(p_kickoff) THEN
    RAISE EXCEPTION 'Play-now kick-off must be on a 10-minute boundary (UK time)';
  END IF;

  IF p_kickoff <= now() THEN
    RAISE EXCEPTION 'That kick-off time has already passed — pick the next UK 10-minute slot';
  END IF;

  IF p_kickoff >= v_schedule.agreed_kickoff_at THEN
    RAISE EXCEPTION 'Play-now kick-off must be earlier than the agreed kick-off';
  END IF;

  IF to_regprocedure('public.match_schedule_fixture_within_play_window(bigint,timestamptz)') IS NOT NULL
     AND NOT public.match_schedule_fixture_within_play_window(p_fixture_id, now())
  THEN
    RAISE EXCEPTION 'This fixture is past its play window — Play now is closed';
  END IF;

  IF to_regprocedure('public.match_schedule_assert_holiday_early_squad_ready(bigint)') IS NOT NULL THEN
    PERFORM public.match_schedule_assert_holiday_early_squad_ready(p_fixture_id);
  END IF;

  IF to_regprocedure('public.match_schedule_assert_kickoff_not_double_booked(bigint,timestamptz)') IS NOT NULL THEN
    PERFORM public.match_schedule_assert_kickoff_not_double_booked(p_fixture_id, p_kickoff);
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_assert_play_now_kickoff_ok(bigint, timestamptz)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.match_schedule_play_now_kickoff(p_fixture_id bigint)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_schedule public.competition_fixture_schedule;
  v_slot timestamptz;
BEGIN
  SELECT * INTO v_schedule
  FROM public.competition_fixture_schedule
  WHERE fixture_id = p_fixture_id;

  IF NOT FOUND OR v_schedule.status <> 'agreed' OR v_schedule.agreed_kickoff_at IS NULL THEN
    RAISE EXCEPTION 'Fixture does not have an agreed kick-off';
  END IF;

  IF now() >= v_schedule.agreed_kickoff_at THEN
    RAISE EXCEPTION 'Play now is only available before the agreed kick-off';
  END IF;

  v_slot := public.match_schedule_current_uk_ten_min_slot();

  -- Next future 10-minute UK slot
  WHILE v_slot <= now() LOOP
    v_slot := v_slot + interval '10 minutes';
  END LOOP;

  IF v_slot >= v_schedule.agreed_kickoff_at THEN
    RAISE EXCEPTION 'No earlier play slot is available before the agreed kick-off';
  END IF;

  PERFORM public.match_schedule_assert_play_now_kickoff_ok(p_fixture_id, v_slot);
  RETURN v_slot;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_play_now_kickoff(bigint)
  TO authenticated, service_role;

-- Keep status helper in sync (suggested slot is now 10-min)
CREATE OR REPLACE FUNCTION public.match_schedule_play_now_status(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_schedule public.competition_fixture_schedule;
  v_kickoff timestamptz;
BEGIN
  SELECT * INTO v_schedule
  FROM public.competition_fixture_schedule
  WHERE fixture_id = p_fixture_id;

  IF NOT FOUND OR v_schedule.status <> 'agreed' OR v_schedule.agreed_kickoff_at IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'can_request', false,
      'kickoff_at', NULL,
      'reason', 'Fixture does not have an agreed kick-off'
    );
  END IF;

  IF now() >= v_schedule.agreed_kickoff_at THEN
    RETURN jsonb_build_object(
      'ok', false,
      'can_request', false,
      'kickoff_at', NULL,
      'reason', 'Play now is only available before the agreed kick-off'
    );
  END IF;

  BEGIN
    v_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);
  EXCEPTION WHEN OTHERS THEN
    v_kickoff := NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'can_request', true,
    'kickoff_at', v_kickoff,
    'reason', NULL
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_play_now_status(bigint)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

SELECT
  public.match_schedule_kickoff_is_ten_min_slot(
    timezone('Europe/London', date_trunc('hour', now() AT TIME ZONE 'Europe/London'))
      AT TIME ZONE 'Europe/London'
  ) AS ten_min_fn_ok,
  (position('ten_min' IN pg_get_functiondef(
    'public.match_schedule_assert_play_now_kickoff_ok(bigint,timestamptz)'::regprocedure
  )) > 0) AS assert_uses_ten_min;
