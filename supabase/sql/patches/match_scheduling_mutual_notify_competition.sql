-- Mutual override notifications with competition labels (run after competition_fixture_inbox_competition.sql)

CREATE OR REPLACE FUNCTION public.match_schedule_mutual_override_apply(p_override_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_override public.competition_fixture_mutual_override;
  v_fixture public.competition_fixtures;
  v_fmt text;
  v_body text;
BEGIN
  SELECT * INTO v_override
  FROM public.competition_fixture_mutual_override
  WHERE id = p_override_id
    AND status = 'pending'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Mutual override not found or no longer pending';
  END IF;

  IF v_override.home_confirmed_at IS NULL OR v_override.away_confirmed_at IS NULL THEN
    RAISE EXCEPTION 'Both clubs must confirm before applying';
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = v_override.fixture_id;

  UPDATE public.competition_fixture_schedule
  SET
    agreed_kickoff_at = v_override.proposed_kickoff_at,
    mutual_override_used = true,
    updated_at = now()
  WHERE fixture_id = v_override.fixture_id;

  DELETE FROM public.competition_fixture_checkin
  WHERE fixture_id = v_override.fixture_id;

  UPDATE public.competition_fixture_mutual_override
  SET status = 'applied', applied_at = now()
  WHERE id = p_override_id;

  UPDATE public.competition_fixture_mutual_override
  SET status = 'cancelled'
  WHERE fixture_id = v_override.fixture_id
    AND status = 'pending'
    AND id <> p_override_id;

  v_fmt := public.match_schedule_format_kickoff_uk(v_override.proposed_kickoff_at);
  v_body := CASE v_override.kind
    WHEN 'play_now' THEN 'Both clubs agreed to play now. New kick-off: ' || v_fmt || E'.\nNo reschedule or emergency allowance was used.'
    ELSE 'Both clubs agreed a new kick-off: ' || v_fmt || E'.\nNo reschedule or emergency allowance was used.'
  END;

  PERFORM public.match_schedule_notify_pair(
    v_fixture,
    'match_mutual_override_applied',
    'Kick-off updated (mutual agreement)',
    v_body,
    NULL,
    'mutual-applied:' || p_override_id::text
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fixture_mutual_override_request(
  p_fixture_id bigint,
  p_kind text,
  p_kickoff_at timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_schedule public.competition_fixture_schedule;
  v_kickoff timestamptz;
  v_override_id bigint;
  v_opponent text;
  v_fmt text;
  v_title text;
  v_body text;
  v_home_confirm timestamptz;
  v_away_confirm timestamptz;
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

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture is not open for scheduling';
  END IF;

  v_schedule := public.match_schedule_ensure_row(p_fixture_id);

  IF v_schedule.status <> 'agreed' OR v_schedule.agreed_kickoff_at IS NULL THEN
    RAISE EXCEPTION 'Kick-off must be agreed before a mutual override';
  END IF;

  IF v_schedule.mutual_override_used THEN
    RAISE EXCEPTION 'This fixture has already used its one mutual kick-off change';
  END IF;

  IF p_kind NOT IN ('play_now', 'new_time') THEN
    RAISE EXCEPTION 'Invalid mutual override kind';
  END IF;

  IF p_kind = 'play_now' THEN
    v_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);
  ELSE
    IF p_kickoff_at IS NULL THEN
      RAISE EXCEPTION 'New kick-off time is required';
    END IF;
    PERFORM public.match_schedule_assert_kickoff_valid(p_fixture_id, p_kickoff_at);
    IF p_kickoff_at = v_schedule.agreed_kickoff_at THEN
      RAISE EXCEPTION 'Choose a different kick-off time';
    END IF;
    v_kickoff := p_kickoff_at;
  END IF;

  UPDATE public.competition_fixture_mutual_override
  SET status = 'cancelled'
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  IF v_club = v_fixture.home_club_short_name THEN
    v_home_confirm := now();
    v_away_confirm := NULL;
  ELSE
    v_home_confirm := NULL;
    v_away_confirm := now();
  END IF;

  INSERT INTO public.competition_fixture_mutual_override (
    fixture_id,
    requested_by_club,
    kind,
    proposed_kickoff_at,
    status,
    home_confirmed_at,
    away_confirmed_at,
    expires_at
  )
  VALUES (
    p_fixture_id,
    v_club,
    p_kind,
    v_kickoff,
    'pending',
    v_home_confirm,
    v_away_confirm,
    now() + interval '24 hours'
  )
  RETURNING id INTO v_override_id;

  v_opponent := public.competition_fixture_opponent(p_fixture_id, v_club);
  v_fmt := public.match_schedule_format_kickoff_uk(v_kickoff);
  v_title := CASE p_kind
    WHEN 'play_now' THEN 'Play now — confirm?'
    ELSE 'New kick-off — confirm?'
  END;
  v_body := v_club || CASE p_kind
    WHEN 'play_now' THEN ' wants to play now at '
    ELSE ' proposed a new kick-off at '
  END || v_fmt || E'.\nConfirm in your inbox or on Schedule match. No reschedule allowance is used when both agree.';

  PERFORM public.match_schedule_notify_opponent(
    v_fixture,
    'match_mutual_override_requested',
    v_title,
    v_body,
    v_opponent,
    'mutual:' || p_fixture_id::text || ':req:' || v_override_id::text || ':' || v_opponent
  );

  RETURN jsonb_build_object(
    'ok', true,
    'override_id', v_override_id,
    'proposed_kickoff_at', v_kickoff,
    'awaiting_opponent', true
  );
END;
$function$;

