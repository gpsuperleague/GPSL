-- Phase 3 step 2/3 — functions (run after step 1 succeeds)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.match_schedule_current_uk_slot()
RETURNS timestamptz
LANGUAGE sql
STABLE
AS $$
  SELECT (
    date_trunc('hour', local_ts)
    + (floor(extract(minute FROM local_ts) / 30)::int * interval '30 minutes')
  ) AT TIME ZONE 'Europe/London'
  FROM (SELECT now() AT TIME ZONE 'Europe/London' AS local_ts) t;
$$;

CREATE OR REPLACE FUNCTION public.match_schedule_play_now_kickoff(p_fixture_id bigint)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_schedule public.competition_fixture_schedule;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_slot timestamptz;
  v_checkin interval;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  SELECT * INTO v_schedule FROM public.competition_fixture_schedule WHERE fixture_id = p_fixture_id;
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

  IF NOT public.match_schedule_kickoff_is_slot(v_slot) THEN
    RAISE EXCEPTION 'Invalid play-now slot';
  END IF;

  SELECT w.unlock_at, w.lock_at INTO v_unlock, v_lock
  FROM public.match_schedule_fixture_month_window(p_fixture_id) w;

  IF v_unlock IS NULL THEN
    RAISE EXCEPTION 'No GPSL month window for this fixture';
  END IF;

  IF v_slot < v_unlock OR v_slot + interval '30 minutes' > v_lock THEN
    RAISE EXCEPTION 'Play-now slot must fall within the GPSL month window';
  END IF;

  RETURN v_slot;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_mutual_override_expire()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE public.competition_fixture_mutual_override
  SET status = 'cancelled'
  WHERE status = 'pending'
    AND expires_at < now();
$$;

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
  v_href text;
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
  v_href := 'fixture_schedule.html?fixture=' || v_fixture.id::text;

  PERFORM public.owner_inbox_send(
    'match_mutual_override_applied',
    'Kick-off updated (mutual agreement)',
    v_body,
    v_fixture.home_club_short_name,
    NULL,
    v_fixture.id,
    NULL, NULL, NULL,
    v_href,
    'mutual:' || v_override.fixture_id::text || ':applied:home:' || p_override_id::text,
    v_fixture.gpsl_month,
    v_fixture.season_id,
    NULL
  );

  PERFORM public.owner_inbox_send(
    'match_mutual_override_applied',
    'Kick-off updated (mutual agreement)',
    v_body,
    v_fixture.away_club_short_name,
    NULL,
    v_fixture.id,
    NULL, NULL, NULL,
    v_href,
    'mutual:' || v_override.fixture_id::text || ':applied:away:' || p_override_id::text,
    v_fixture.gpsl_month,
    v_fixture.season_id,
    NULL
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
  v_href text;
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
  v_href := 'fixture_schedule.html?fixture=' || p_fixture_id::text;

  PERFORM public.owner_inbox_send(
    'match_mutual_override_requested',
    v_title,
    v_body,
    v_opponent,
    NULL,
    p_fixture_id,
    NULL, NULL, NULL,
    v_href,
    'mutual:' || p_fixture_id::text || ':req:' || v_override_id::text || ':' || v_opponent,
    v_fixture.gpsl_month,
    v_fixture.season_id,
    NULL
  );

  RETURN jsonb_build_object(
    'ok', true,
    'override_id', v_override_id,
    'proposed_kickoff_at', v_kickoff,
    'awaiting_opponent', true
  );
END;
$function$;

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

CREATE OR REPLACE FUNCTION public.fixture_mutual_override_cancel(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_n integer;
BEGIN
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

  UPDATE public.competition_fixture_mutual_override
  SET status = 'cancelled'
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  GET DIAGNOSTICS v_n = ROW_COUNT;

  IF v_n = 0 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'code', 'no_pending',
      'message', 'No pending mutual override to cancel.'
    );
  END IF;

  RETURN jsonb_build_object('ok', true, 'message', 'Mutual override cancelled.');
END;
$function$;

-- ---------------------------------------------------------------------------
-- Extend fixture context (Phase 3 fields)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.match_schedule_fixture_context(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_schedule public.competition_fixture_schedule;
  v_schedule_found boolean := false;
  v_pending public.competition_fixture_schedule_proposal;
  v_override public.competition_fixture_mutual_override;
  v_role text;
  v_home text;
  v_away text;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_slots jsonb;
  v_status text;
  v_agreed timestamptz;
  v_home_count smallint;
  v_away_count smallint;
  v_discord_hint boolean;
  v_pending_id bigint;
  v_mutual_used boolean := false;
  v_kickoff timestamptz;
  v_home_in boolean := false;
  v_away_in boolean := false;
  v_my_in boolean := false;
  v_emergency_used integer;
  v_reschedule_used boolean;
  v_play_now_kickoff timestamptz;
  v_can_play_now boolean := false;
  v_can_mutual_new_time boolean := false;
  v_my_override_confirmed boolean := false;
  v_can_confirm_override boolean := false;
  v_can_cancel_override boolean := false;
BEGIN
  PERFORM public.match_schedule_mutual_override_expire();

  v_club := public.my_club_shortname();

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF NOT public.is_gpsl_admin()
     AND v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name)
  THEN
    RAISE EXCEPTION 'You are not in this fixture';
  END IF;

  PERFORM public.fixture_try_checkin_forfeit(p_fixture_id);

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;

  v_home := v_fixture.home_club_short_name;
  v_away := v_fixture.away_club_short_name;

  IF v_club = v_home THEN v_role := 'home';
  ELSIF v_club = v_away THEN v_role := 'away';
  ELSE v_role := 'admin';
  END IF;

  SELECT * INTO v_schedule FROM public.competition_fixture_schedule WHERE fixture_id = p_fixture_id;
  v_schedule_found := FOUND;

  IF v_schedule_found THEN
    v_status := v_schedule.status;
    v_agreed := v_schedule.agreed_kickoff_at;
    v_home_count := v_schedule.home_proposal_count;
    v_away_count := v_schedule.away_proposal_count;
    v_discord_hint := v_schedule.discord_hint_shown;
    v_pending_id := v_schedule.pending_proposal_id;
    v_mutual_used := COALESCE(v_schedule.mutual_override_used, false);
  ELSE
    v_status := 'unscheduled';
    v_agreed := NULL;
    v_home_count := 0;
    v_away_count := 0;
    v_discord_hint := false;
    v_pending_id := NULL;
    v_mutual_used := false;
  END IF;

  IF v_pending_id IS NOT NULL THEN
    SELECT * INTO v_pending
    FROM public.competition_fixture_schedule_proposal
    WHERE id = v_pending_id;
  END IF;

  SELECT * INTO v_override
  FROM public.competition_fixture_mutual_override
  WHERE fixture_id = p_fixture_id
    AND status = 'pending'
  ORDER BY created_at DESC
  LIMIT 1;

  SELECT w.unlock_at, w.lock_at INTO v_unlock, v_lock
  FROM public.match_schedule_fixture_month_window(p_fixture_id) w;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object('iso_dow', s.iso_dow, 'hour', s.slot_minute / 60, 'minute', s.slot_minute % 60)
    ORDER BY s.iso_dow, s.slot_minute
  ), '[]'::jsonb)
  INTO v_slots
  FROM public.club_owner_availability_slot s
  WHERE s.season_id = v_fixture.season_id AND s.club_short_name = v_club;

  v_kickoff := v_agreed;
  IF v_kickoff IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_home
    ) INTO v_home_in;
    SELECT EXISTS (
      SELECT 1 FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_away
    ) INTO v_away_in;
    IF v_club IS NOT NULL THEN
      SELECT EXISTS (
        SELECT 1 FROM public.competition_fixture_checkin c
        WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_club
      ) INTO v_my_in;
    END IF;
  END IF;

  v_emergency_used := public.match_schedule_emergency_drops_used(v_fixture.season_id, v_club);
  v_reschedule_used := public.match_schedule_reschedule_used_this_month(
    v_fixture.season_id, v_club, v_fixture.gpsl_month
  );

  IF v_fixture.status = 'scheduled'
     AND v_status = 'agreed'
     AND v_agreed IS NOT NULL
     AND NOT v_mutual_used
     AND v_override.id IS NULL
  THEN
    BEGIN
      v_play_now_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);
      v_can_play_now := true;
    EXCEPTION WHEN OTHERS THEN
      v_can_play_now := false;
      v_play_now_kickoff := NULL;
    END;
    v_can_mutual_new_time := now() < v_agreed;
  END IF;

  IF v_override.id IS NOT NULL AND v_club IS NOT NULL THEN
    IF v_club = v_home THEN
      v_my_override_confirmed := v_override.home_confirmed_at IS NOT NULL;
    ELSE
      v_my_override_confirmed := v_override.away_confirmed_at IS NOT NULL;
    END IF;

    v_can_confirm_override := (
      NOT v_my_override_confirmed
      AND v_override.requested_by_club <> v_club
    );
    v_can_cancel_override := v_my_override_confirmed OR v_override.requested_by_club = v_club;
  END IF;

  RETURN jsonb_build_object(
    'fixture', jsonb_build_object(
      'id', v_fixture.id,
      'gpsl_month', v_fixture.gpsl_month,
      'home_club_short_name', v_home,
      'away_club_short_name', v_away,
      'status', v_fixture.status,
      'competition_type', v_fixture.competition_type,
      'is_forfeit', v_fixture.is_forfeit
    ),
    'schedule', jsonb_build_object(
      'status', v_status,
      'agreed_kickoff_at', v_agreed,
      'home_proposal_count', v_home_count,
      'away_proposal_count', v_away_count,
      'discord_hint_shown', v_discord_hint,
      'mutual_override_used', v_mutual_used
    ),
    'pending_proposal', CASE WHEN v_pending.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', v_pending.id,
      'proposed_by_club_short_name', v_pending.proposed_by_club_short_name,
      'kickoff_at', v_pending.kickoff_at
    ) END,
    'mutual_override', CASE WHEN v_override.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', v_override.id,
      'kind', v_override.kind,
      'proposed_kickoff_at', v_override.proposed_kickoff_at,
      'requested_by_club_short_name', v_override.requested_by_club,
      'expires_at', v_override.expires_at,
      'my_confirmed', v_my_override_confirmed,
      'can_confirm', v_can_confirm_override,
      'can_cancel', v_can_cancel_override
    ) END,
    'my_role', v_role,
    'month_window', jsonb_build_object('unlock_at', v_unlock, 'lock_at', v_lock),
    'my_timezone', public.match_schedule_club_timezone(v_club),
    'home_timezone', public.match_schedule_club_timezone(v_home),
    'away_timezone', public.match_schedule_club_timezone(v_away),
    'my_weekly_slots', v_slots,
    'intersection_slots', (
      SELECT COALESCE(jsonb_agg(i.kickoff_at ORDER BY i.kickoff_at), '[]'::jsonb)
      FROM public.match_schedule_intersection_slots(p_fixture_id) i
    ),
    'can_propose_first', (v_role = 'home' AND v_status = 'unscheduled' AND v_fixture.status = 'scheduled'),
    'can_respond', (
      v_pending.id IS NOT NULL
      AND v_pending.proposed_by_club_short_name <> v_club
      AND v_status = 'negotiating'
    ),
    'mutual_override_options', jsonb_build_object(
      'can_request_play_now', v_can_play_now,
      'play_now_kickoff_at', v_play_now_kickoff,
      'can_request_new_time', v_can_mutual_new_time
    ),
    'checkin', jsonb_build_object(
      'home_checked_in', v_home_in,
      'away_checked_in', v_away_in,
      'my_checked_in', v_my_in,
      'window_opens_at', v_kickoff,
      'window_closes_at', CASE WHEN v_kickoff IS NULL THEN NULL
        ELSE v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval END,
      'play_block_ends_at', CASE WHEN v_kickoff IS NULL THEN NULL
        ELSE v_kickoff + (public.match_schedule_block_minutes() || ' minutes')::interval END,
      'can_check_in', (
        v_fixture.status = 'scheduled'
        AND v_kickoff IS NOT NULL
        AND now() >= v_kickoff
        AND now() < v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval
        AND NOT v_my_in
      ),
      'can_play', (
        v_fixture.status = 'scheduled'
        AND v_kickoff IS NOT NULL
        AND v_home_in AND v_away_in
        AND now() >= v_kickoff
        AND now() < v_kickoff + (public.match_schedule_block_minutes() || ' minutes')::interval
      )
    ),
    'allowances', jsonb_build_object(
      'emergency_drops_used', v_emergency_used,
      'emergency_drops_remaining', greatest(0, 2 - v_emergency_used),
      'reschedule_used_this_month', v_reschedule_used,
      'can_voluntary_drop', (
        v_fixture.status = 'scheduled'
        AND v_kickoff IS NOT NULL
        AND now() <= v_kickoff - interval '24 hours'
        AND NOT v_reschedule_used
        AND v_override.id IS NULL
      ),
      'can_emergency_drop', (
        v_fixture.status = 'scheduled'
        AND v_kickoff IS NOT NULL
        AND now() < v_kickoff
        AND now() > v_kickoff - interval '24 hours'
        AND v_override.id IS NULL
      )
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.fixture_mutual_override_request(bigint, text, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fixture_mutual_override_confirm(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fixture_mutual_override_cancel(bigint) TO authenticated;