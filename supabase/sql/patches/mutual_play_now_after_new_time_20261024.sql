-- =============================================================================
-- Mutual override: Play now stays available after free new-time used (2026-10-24)
-- =============================================================================
-- Before: mutual_override_used blocked both Play now and "new time" (one change).
-- After:
--   • mutual_override_used = free mutual "new time" already used (still one-shot)
--   • Play now remains available whenever there is a future agreed kick-off
--     (same play_now_kickoff checks; both clubs still confirm; no allowance used)
-- Safe re-run.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.fixture_mutual_override_request(p_fixture_id bigint, p_kind text, p_kickoff_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
  v_pre_agree boolean;
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
  v_pre_agree := coalesce(v_schedule.status, 'unscheduled') <> 'agreed'
    OR v_schedule.agreed_kickoff_at IS NULL;

  IF p_kind NOT IN ('play_now', 'new_time') THEN
    RAISE EXCEPTION 'Invalid mutual override kind';
  END IF;

  IF v_pre_agree THEN
    -- Discord / first lock: only new_time (datetime pick). Does not use mutual allowance.
    IF p_kind <> 'new_time' THEN
      RAISE EXCEPTION 'Agree a kick-off on the schedule page first (or use Discord lock with a chosen time)';
    END IF;
    IF p_kickoff_at IS NULL THEN
      RAISE EXCEPTION 'Kick-off time is required';
    END IF;
    PERFORM public.match_schedule_assert_mutual_kickoff_ok(p_fixture_id, p_kickoff_at);
    v_kickoff := p_kickoff_at;
  ELSE
    -- mutual_override_used = free "new time" already spent.
    -- Play now stays available on any future agreed kick-off (both still confirm).
    IF p_kind = 'new_time' AND v_schedule.mutual_override_used THEN
      RAISE EXCEPTION 'This fixture has already used its one free mutual new-time change';
    END IF;

    IF p_kind = 'play_now' THEN
      v_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);
      IF to_regprocedure('public.match_schedule_assert_kickoff_not_double_booked(bigint,timestamptz)') IS NOT NULL THEN
        PERFORM public.match_schedule_assert_kickoff_not_double_booked(p_fixture_id, v_kickoff);
      END IF;
    ELSE
      IF p_kickoff_at IS NULL THEN
        RAISE EXCEPTION 'New kick-off time is required';
      END IF;
      IF p_kickoff_at = v_schedule.agreed_kickoff_at THEN
        RAISE EXCEPTION 'Choose a different kick-off time';
      END IF;
      v_kickoff := p_kickoff_at;
      IF to_regprocedure('public.match_schedule_assert_mutual_kickoff_ok(bigint,timestamptz)') IS NOT NULL THEN
        PERFORM public.match_schedule_assert_mutual_kickoff_ok(p_fixture_id, v_kickoff);
      ELSE
        PERFORM public.match_schedule_assert_kickoff_valid(p_fixture_id, v_kickoff);
      END IF;
    END IF;
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

  IF v_pre_agree THEN
    v_title := 'Discord kick-off 窶・confirm?';
    v_body := coalesce(public.club_display_name(v_club), v_club)
      || ' wants to lock the Discord-agreed kick-off at '
      || v_fmt
      || E'.\nConfirm in your inbox or on Schedule match. Reply and arrangement deadlines keep running until both lock.';
  ELSIF p_kind = 'play_now' THEN
    v_title := 'Play now requested';
    v_body := coalesce(public.club_display_name(v_club), v_club)
      || ' proposed play now at '
      || v_fmt
      || E'.\nConfirm in your inbox or on Schedule match. No reschedule allowance is used when both agree.';
  ELSE
    v_title := 'New kick-off requested';
    v_body := coalesce(public.club_display_name(v_club), v_club)
      || ' proposed a new kick-off at '
      || v_fmt
      || E'.\nConfirm in your inbox or on Schedule match. No reschedule allowance is used when both agree.';
  END IF;

  PERFORM public.match_schedule_notify_opponent(
    v_fixture,
    'match_mutual_override_requested',
    v_title,
    v_body,
    v_opponent,
    'mutual:' || v_override_id::text || ':' || v_opponent,
    NULL
  );

  RETURN jsonb_build_object(
    'ok', true,
    'override_id', v_override_id,
    'kind', p_kind,
    'proposed_kickoff_at', v_kickoff,
    'pre_agree_lock', v_pre_agree,
    'awaiting_opponent', true
  );
END;
$function$;
CREATE OR REPLACE FUNCTION public.match_schedule_mutual_override_apply(p_override_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_override public.competition_fixture_mutual_override;
  v_fixture public.competition_fixtures;
  v_schedule public.competition_fixture_schedule;
  v_fmt text;
  v_body text;
  v_was_agreed boolean;
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
  v_schedule := public.match_schedule_ensure_row(v_override.fixture_id);
  v_was_agreed := coalesce(v_schedule.status, '') = 'agreed'
    AND v_schedule.agreed_kickoff_at IS NOT NULL;

  -- Supersede any open proposals when locking from Discord / negotiation
  UPDATE public.competition_fixture_schedule_proposal
  SET status = 'superseded'
  WHERE fixture_id = v_override.fixture_id
    AND status = 'pending';

  UPDATE public.competition_fixture_schedule
  SET
    status = 'agreed',
    agreed_kickoff_at = v_override.proposed_kickoff_at,
    pending_proposal_id = NULL,
    response_due_at = NULL,
    response_required_club_short_name = NULL,
    response_miss_count = 0,
    response_deadline_warned_at = NULL,
    -- Only a free "new time" burns the one-shot flag. Play now never does.
    mutual_override_used = CASE
      WHEN v_was_agreed AND v_override.kind = 'new_time' THEN true
      ELSE coalesce(mutual_override_used, false)
    END,
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
  IF NOT v_was_agreed THEN
    v_body := 'Both clubs locked kick-off (Discord / mutual confirm): '
      || v_fmt
      || E'.\nCheck-in opens 10 minutes before kick-off.';
  ELSIF v_override.kind = 'play_now' THEN
    v_body := 'Both clubs agreed to play now. New kick-off: '
      || v_fmt
      || E'.\nNo reschedule or emergency allowance was used.';
  ELSE
    v_body := 'Both clubs agreed a new kick-off: '
      || v_fmt
      || E'.\nNo reschedule or emergency allowance was used.';
  END IF;

  PERFORM public.match_schedule_notify_pair(
    v_fixture,
    'match_mutual_override_applied',
    CASE WHEN v_was_agreed THEN 'Kick-off updated (mutual agreement)' ELSE 'Kick-off locked (mutual agreement)' END,
    v_body,
    NULL,
    'mutual-applied:' || p_override_id::text
  );
END;
$function$;
CREATE OR REPLACE FUNCTION public.match_schedule_fixture_context(p_fixture_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
  v_prop_unlock timestamptz;
  v_prop_lock timestamptz;
  v_prop_month text;
  v_prop_catch_up boolean := false;
  v_prop_holiday_early boolean := false;
  v_is_catch_up boolean := false;
  v_is_holiday_early boolean := false;
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
  v_can_catch_up_reset boolean := false;
  v_can_replay_reset boolean := false;
  v_has_mgr boolean := false;
BEGIN
  PERFORM public.match_schedule_mutual_override_expire();
  v_club := public.my_club_shortname();
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Fixture not found'; END IF;
  IF NOT public.is_gpsl_admin()
     AND v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name)
  THEN RAISE EXCEPTION 'You are not in this fixture'; END IF;
  PERFORM public.fixture_try_checkin_forfeit(p_fixture_id);
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  v_is_catch_up := public.match_schedule_fixture_is_catch_up(p_fixture_id);
  IF to_regprocedure('public.match_schedule_fixture_is_holiday_early(bigint)') IS NOT NULL THEN
    v_is_holiday_early := public.match_schedule_fixture_is_holiday_early(p_fixture_id);
  END IF;
  v_home := v_fixture.home_club_short_name;
  v_away := v_fixture.away_club_short_name;
  IF v_club = v_home THEN v_role := 'home';
  ELSIF v_club = v_away THEN v_role := 'away';
  ELSE v_role := 'admin'; END IF;
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
    v_status := 'unscheduled'; v_agreed := NULL;
    v_home_count := 0; v_away_count := 0; v_discord_hint := false;
    v_pending_id := NULL; v_mutual_used := false;
  END IF;
  IF v_pending_id IS NOT NULL THEN
    SELECT * INTO v_pending FROM public.competition_fixture_schedule_proposal WHERE id = v_pending_id;
  END IF;
  SELECT * INTO v_override FROM public.competition_fixture_mutual_override
  WHERE fixture_id = p_fixture_id AND status = 'pending' ORDER BY created_at DESC LIMIT 1;
  SELECT w.unlock_at, w.lock_at INTO v_unlock, v_lock FROM public.match_schedule_fixture_month_window(p_fixture_id) w;
  SELECT w.unlock_at, w.lock_at, w.gpsl_month, w.is_catch_up, w.is_holiday_early
  INTO v_prop_unlock, v_prop_lock, v_prop_month, v_prop_catch_up, v_prop_holiday_early
  FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w;
  v_slots := public.match_schedule_club_weekly_slots_json(v_fixture.season_id, v_club);
  IF to_regprocedure('public.club_has_signed_manager(text)') IS NOT NULL THEN
    v_has_mgr := coalesce(public.club_has_signed_manager(v_club), false);
  ELSE
    v_has_mgr := true;
  END IF;
  v_kickoff := v_agreed;
  IF v_kickoff IS NOT NULL THEN
    SELECT EXISTS (SELECT 1 FROM public.competition_fixture_checkin c WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_home) INTO v_home_in;
    SELECT EXISTS (SELECT 1 FROM public.competition_fixture_checkin c WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_away) INTO v_away_in;
    IF v_club IS NOT NULL THEN
      SELECT EXISTS (SELECT 1 FROM public.competition_fixture_checkin c WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_club) INTO v_my_in;
    END IF;
  END IF;
  v_emergency_used := public.match_schedule_emergency_drops_used(v_fixture.season_id, v_club);
  v_reschedule_used := public.match_schedule_reschedule_used_this_month(v_fixture.season_id, v_club, v_fixture.gpsl_month);
  IF v_is_catch_up AND v_fixture.status = 'scheduled' THEN
    v_can_catch_up_reset := v_status IN ('agreed', 'negotiating')
      AND (v_kickoff IS NULL OR v_kickoff < now() OR NOT public.match_schedule_kickoff_in_proposal_window(p_fixture_id, v_kickoff))
      AND v_override.id IS NULL;
  END IF;
  IF NOT v_is_catch_up
     AND v_fixture.status = 'scheduled'
     AND public.match_schedule_fixture_play_month_open(p_fixture_id)
     AND v_status = 'agreed'
     AND v_kickoff IS NOT NULL
     AND v_kickoff < now()
     AND v_override.id IS NULL
  THEN
    v_can_replay_reset := true;
  END IF;
  -- Play now: available on any future agreed KO (not gated by mutual_override_used).
  -- Free mutual new-time: one-shot per fixture (mutual_override_used).
  IF v_fixture.status = 'scheduled' AND v_status = 'agreed' AND v_agreed IS NOT NULL AND v_override.id IS NULL THEN
    BEGIN
      v_play_now_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);
      v_can_play_now := true;
    EXCEPTION WHEN OTHERS THEN
      v_can_play_now := false; v_play_now_kickoff := NULL;
    END;
    v_can_mutual_new_time := (NOT v_mutual_used) AND now() < v_agreed;
  END IF;
  IF v_override.id IS NOT NULL AND v_club IS NOT NULL THEN
    IF v_club = v_home THEN v_my_override_confirmed := v_override.home_confirmed_at IS NOT NULL;
    ELSE v_my_override_confirmed := v_override.away_confirmed_at IS NOT NULL; END IF;
    v_can_confirm_override := NOT v_my_override_confirmed AND v_override.requested_by_club <> v_club;
    v_can_cancel_override := true; -- either club may decline / cancel a pending Discord lock
  END IF;
  RETURN jsonb_build_object(
    'fixture', jsonb_build_object('id', v_fixture.id, 'gpsl_month', v_fixture.gpsl_month, 'division', v_fixture.division, 'cup_code', v_fixture.cup_code, 'home_club_short_name', v_home, 'away_club_short_name', v_away, 'status', v_fixture.status, 'competition_type', v_fixture.competition_type, 'is_forfeit', v_fixture.is_forfeit, 'is_catch_up', v_is_catch_up, 'is_holiday_early', v_is_holiday_early),
    'schedule', jsonb_build_object('status', v_status, 'agreed_kickoff_at', v_agreed, 'home_proposal_count', v_home_count, 'away_proposal_count', v_away_count, 'discord_hint_shown', v_discord_hint, 'mutual_override_used', v_mutual_used, 'response_due_at', CASE WHEN v_schedule_found THEN v_schedule.response_due_at ELSE NULL END, 'response_required_club_short_name', CASE WHEN v_schedule_found THEN v_schedule.response_required_club_short_name ELSE NULL END, 'response_miss_count', CASE WHEN v_schedule_found THEN coalesce(v_schedule.response_miss_count, 0) ELSE 0 END),
    'pending_proposal', CASE WHEN v_pending.id IS NULL THEN NULL ELSE jsonb_build_object('id', v_pending.id, 'proposed_by_club_short_name', v_pending.proposed_by_club_short_name, 'kickoff_at', v_pending.kickoff_at) END,
    'mutual_override', CASE WHEN v_override.id IS NULL THEN NULL ELSE jsonb_build_object('id', v_override.id, 'kind', v_override.kind, 'proposed_kickoff_at', v_override.proposed_kickoff_at, 'requested_by_club_short_name', v_override.requested_by_club, 'expires_at', v_override.expires_at, 'my_confirmed', v_my_override_confirmed, 'can_confirm', v_can_confirm_override, 'can_cancel', v_can_cancel_override) END,
    'my_role', v_role, 'is_catch_up', v_is_catch_up, 'is_holiday_early', v_is_holiday_early,
    'my_has_manager', v_has_mgr,
    'month_window', jsonb_build_object('unlock_at', v_unlock, 'lock_at', v_lock),
    'proposal_window', jsonb_build_object('unlock_at', v_prop_unlock, 'lock_at', v_prop_lock, 'gpsl_month', v_prop_month, 'is_catch_up', coalesce(v_prop_catch_up, false), 'is_holiday_early', coalesce(v_prop_holiday_early, false)),
    'my_timezone', public.match_schedule_club_timezone(v_club),
    'home_timezone', public.match_schedule_club_timezone(v_home),
    'away_timezone', public.match_schedule_club_timezone(v_away),
    'my_weekly_slots', v_slots,
    'my_window_slots', (SELECT COALESCE(jsonb_agg(i.kickoff_at ORDER BY i.kickoff_at), '[]'::jsonb) FROM public.match_schedule_club_window_slots(p_fixture_id, v_club) i),
    'intersection_slots', (SELECT COALESCE(jsonb_agg(i.kickoff_at ORDER BY i.kickoff_at), '[]'::jsonb) FROM public.match_schedule_intersection_slots(p_fixture_id) i),
    'manual_black_box', (
      to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
      AND public.fixture_is_manual_black_box(p_fixture_id)
    ),
    'can_propose_first', (
      v_role = 'home' AND v_status = 'unscheduled' AND v_fixture.status = 'scheduled' AND v_has_mgr
      AND NOT (
        to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
        AND public.fixture_is_manual_black_box(p_fixture_id)
      )
    ),
    'can_respond', (
      v_pending.id IS NOT NULL AND v_pending.proposed_by_club_short_name <> v_club
      AND v_status = 'negotiating' AND v_has_mgr
      AND NOT (
        to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
        AND public.fixture_is_manual_black_box(p_fixture_id)
      )
    ),
    'response_deadline', public.match_schedule_response_deadline_json(p_fixture_id, v_club),
    'mutual_override_options', jsonb_build_object('can_request_play_now', v_can_play_now, 'play_now_kickoff_at', v_play_now_kickoff, 'can_request_new_time', v_can_mutual_new_time),
    'checkin', jsonb_build_object('home_checked_in', v_home_in, 'away_checked_in', v_away_in, 'my_checked_in', v_my_in, 'window_opens_at', public.match_schedule_checkin_opens_at(v_kickoff), 'window_closes_at', CASE WHEN v_kickoff IS NULL THEN NULL ELSE v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval END, 'play_block_ends_at', CASE WHEN v_kickoff IS NULL THEN NULL ELSE v_kickoff + (public.match_schedule_block_minutes() || ' minutes')::interval END, 'can_check_in', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() >= public.match_schedule_checkin_opens_at(v_kickoff) AND now() < v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval AND NOT v_my_in AND v_has_mgr), 'can_play', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND v_home_in AND v_away_in AND now() >= v_kickoff AND now() < v_kickoff + (public.match_schedule_block_minutes() || ' minutes')::interval)),
    'allowances', jsonb_build_object('emergency_drops_used', v_emergency_used, 'emergency_drops_remaining', greatest(0, 2 - v_emergency_used), 'reschedule_used_this_month', v_reschedule_used, 'can_voluntary_drop', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() <= v_kickoff - interval '24 hours' AND NOT v_reschedule_used AND v_override.id IS NULL AND NOT v_is_catch_up), 'can_emergency_drop', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() < v_kickoff AND now() > v_kickoff - interval '24 hours' AND v_override.id IS NULL AND NOT v_is_catch_up), 'can_catch_up_reset', v_can_catch_up_reset, 'can_replay_reset', v_can_replay_reset)
  );
END;
$function$;
GRANT EXECUTE ON FUNCTION public.fixture_mutual_override_request(bigint, text, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_schedule_mutual_override_apply(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.match_schedule_fixture_context(bigint) TO authenticated;
