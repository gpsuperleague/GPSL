-- =============================================================================
-- Play now: once a kick-off is agreed, do NOT gate on the GPSL arrange unlock
-- (e.g. active-month Thu 19:00). Clubs may pick any earlier UK 30-min slot
-- before the agreed KO (still not double-booked; holiday-early squad if needed).
--
-- Fixes: September / holiday fixtures blocked with
--   "must fall within the GPSL arrange window (Thu … 19:00 – …)"
-- when trying to Play now before that week's unlock.
--
-- Safe re-run.
-- =============================================================================

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

  IF NOT public.match_schedule_kickoff_is_slot(p_kickoff) THEN
    RAISE EXCEPTION 'Kick-off must be on a 30-minute boundary (UK time)';
  END IF;

  IF p_kickoff <= now() THEN
    RAISE EXCEPTION 'That kick-off time has already passed — pick the next UK 30-minute slot';
  END IF;

  IF p_kickoff >= v_schedule.agreed_kickoff_at THEN
    RAISE EXCEPTION 'Play-now kick-off must be earlier than the agreed kick-off';
  END IF;

  -- Still inside the fixture play/grace window (not past final award lock)
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

-- Keep suggested "now" slot helper aligned (no arrange-window check)
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
  v_checkin interval;
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

  v_checkin := (public.match_schedule_checkin_minutes() || ' minutes')::interval;
  v_slot := public.match_schedule_current_uk_slot();

  IF now() >= v_slot + v_checkin THEN
    v_slot := v_slot + interval '30 minutes';
  END IF;

  IF v_slot >= v_schedule.agreed_kickoff_at THEN
    RAISE EXCEPTION 'No earlier play slot is available before the agreed kick-off';
  END IF;

  PERFORM public.match_schedule_assert_play_now_kickoff_ok(p_fixture_id, v_slot);
  RETURN v_slot;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.match_schedule_play_now_kickoff(bigint)
  TO authenticated, service_role;

-- Confirm path (receiving owner): re-check the *proposed* play-now KO with the
-- relaxed assert — never recompute "now" and never use arrange-window / availability.
CREATE OR REPLACE FUNCTION public.fixture_mutual_override_confirm(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_override public.competition_fixture_mutual_override;
  v_applied boolean := false;
BEGIN
  PERFORM public.match_schedule_mutual_override_expire();

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'You are not in this fixture';
  END IF;

  SELECT * INTO v_override
  FROM public.competition_fixture_mutual_override
  WHERE fixture_id = p_fixture_id
    AND status = 'pending'
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'code', 'no_pending',
      'message', 'There is no pending mutual override for this fixture.'
    );
  END IF;

  IF v_override.requested_by_club = v_club THEN
    RETURN jsonb_build_object(
      'ok', false,
      'code', 'already_confirmed',
      'message', 'You already confirmed — waiting for your opponent.'
    );
  END IF;

  -- Receiving owner: validate the requested play-now time with relaxed rules
  IF v_override.kind = 'play_now'
     AND to_regprocedure('public.match_schedule_assert_play_now_kickoff_ok(bigint,timestamptz)') IS NOT NULL
  THEN
    PERFORM public.match_schedule_assert_play_now_kickoff_ok(
      p_fixture_id,
      v_override.proposed_kickoff_at
    );
  END IF;

  IF v_club = v_fixture.home_club_short_name THEN
    IF v_override.home_confirmed_at IS NOT NULL THEN
      RETURN jsonb_build_object(
        'ok', false,
        'code', 'already_confirmed',
        'message', 'Your club has already confirmed this override.'
      );
    END IF;
    UPDATE public.competition_fixture_mutual_override
    SET home_confirmed_at = now()
    WHERE id = v_override.id;
  ELSE
    IF v_override.away_confirmed_at IS NOT NULL THEN
      RETURN jsonb_build_object(
        'ok', false,
        'code', 'already_confirmed',
        'message', 'Your club has already confirmed this override.'
      );
    END IF;
    UPDATE public.competition_fixture_mutual_override
    SET away_confirmed_at = now()
    WHERE id = v_override.id;
  END IF;

  SELECT * INTO v_override
  FROM public.competition_fixture_mutual_override
  WHERE id = v_override.id;

  IF v_override.home_confirmed_at IS NOT NULL AND v_override.away_confirmed_at IS NOT NULL THEN
    PERFORM public.match_schedule_mutual_override_apply(v_override.id);
    v_applied := true;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'applied', v_applied,
    'message', CASE
      WHEN v_applied THEN 'Kick-off updated — both clubs agreed.'
      ELSE 'Confirmed — waiting for your opponent.'
    END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.fixture_mutual_override_confirm(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT
  (position('arrange window' IN pg_get_functiondef(
    'public.match_schedule_assert_play_now_kickoff_ok(bigint,timestamptz)'::regprocedure
  )) = 0) AS play_now_ignores_arrange_unlock,
  (position('match_schedule_assert_play_now_kickoff_ok' IN pg_get_functiondef(
    'public.fixture_mutual_override_confirm(bigint)'::regprocedure
  )) > 0) AS confirm_uses_relaxed_play_now;
