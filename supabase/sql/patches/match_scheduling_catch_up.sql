-- =============================================================================
-- Match scheduling — Phase 2 catch-up fixtures
-- Run after: match_scheduling_arrangement_fines.sql, match_scheduling_past_slots.sql,
--            match_scheduling_context_competition_fields.sql, club_owner_holidays.sql
-- =============================================================================
-- Unplayed league fixtures after their play GPSL month closes become catch-up:
--   • Highlighted in UI (is_catch_up on fixtures view + schedule context)
--   • Result entry allowed during any later active GPSL month
--   • New proposals use the active GPSL month window (not original play month)
--   • Stale agreed kick-offs can be reset without using reschedule allowance
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Catch-up detection
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.match_schedule_fixture_play_month_closed(p_fixture_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.competition_fixtures f
    JOIN public.competition_season_calendar cal
      ON cal.season_id = f.season_id
     AND cal.gpsl_month = f.gpsl_month
    WHERE f.id = p_fixture_id
      AND cal.lock_at IS NOT NULL
      AND now() >= cal.lock_at
  );
$$;

CREATE OR REPLACE FUNCTION public.match_schedule_fixture_is_catch_up(p_fixture_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.competition_fixtures f
    WHERE f.id = p_fixture_id
      AND f.competition_type = 'league'
      AND f.status = 'scheduled'
      AND public.match_schedule_fixture_play_month_closed(p_fixture_id)
  );
$$;

-- Kick-off window for scheduling proposals (play month, or active month if catch-up)
CREATE OR REPLACE FUNCTION public.match_schedule_proposal_kickoff_window(p_fixture_id bigint)
RETURNS TABLE (
  unlock_at timestamptz,
  lock_at timestamptz,
  gpsl_month text,
  is_catch_up boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_active text;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF public.match_schedule_fixture_is_catch_up(p_fixture_id) THEN
    v_active := public.competition_active_gpsl_month(v_fixture.season_id, now());

    IF v_active IS NULL THEN
      RETURN;
    END IF;

    RETURN QUERY
    SELECT cal.unlock_at, cal.lock_at, cal.gpsl_month, true
    FROM public.competition_season_calendar cal
    WHERE cal.season_id = v_fixture.season_id
      AND cal.gpsl_month = v_active;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT w.unlock_at, w.lock_at, w.gpsl_month, false
  FROM public.match_schedule_fixture_month_window(p_fixture_id) w;
END;
$function$;

CREATE OR REPLACE FUNCTION public.match_schedule_kickoff_in_proposal_window(
  p_fixture_id bigint,
  p_kickoff timestamptz
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w
    WHERE p_kickoff >= w.unlock_at
      AND p_kickoff + interval '30 minutes' <= w.lock_at
  );
$$;

-- ---------------------------------------------------------------------------
-- Scheduling slots + kick-off validation (catch-up uses active month)
-- ---------------------------------------------------------------------------

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

  SELECT w.unlock_at, w.lock_at
  INTO v_unlock, v_lock
  FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w;

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
  v_window_month text;
  v_is_catch_up boolean;
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

  SELECT w.unlock_at, w.lock_at, w.gpsl_month, w.is_catch_up
  INTO v_unlock, v_lock, v_window_month, v_is_catch_up
  FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w;

  IF v_unlock IS NULL THEN
    IF public.match_schedule_fixture_is_catch_up(p_fixture_id) THEN
      RAISE EXCEPTION 'Catch-up scheduling opens when the current GPSL month is active';
    END IF;
    RAISE EXCEPTION 'No GPSL month window for this fixture';
  END IF;

  IF p_kickoff < v_unlock OR p_kickoff + interval '30 minutes' > v_lock THEN
    IF coalesce(v_is_catch_up, false) THEN
      RAISE EXCEPTION 'Catch-up kick-off must fall within GPSL % (% – % UK)',
        public.competition_gpsl_month_label(v_window_month),
        public.match_schedule_format_kickoff_uk(v_unlock),
        public.match_schedule_format_kickoff_uk(v_lock);
    END IF;
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

  SELECT w.unlock_at, w.lock_at
  INTO v_unlock, v_lock
  FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w;

  IF v_unlock IS NULL THEN
    RAISE EXCEPTION 'No GPSL month window for this fixture';
  END IF;

  IF v_slot < v_unlock OR v_slot + interval '30 minutes' > v_lock THEN
    RAISE EXCEPTION 'Play-now slot must fall within the GPSL month window';
  END IF;

  RETURN v_slot;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Calendar guard — allow result entry for catch-up in a later GPSL month
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
  v_active text;
  v_unlock timestamptz;
  v_lock timestamptz;
  v_club text;
BEGIN
  IF public.is_gpsl_admin() THEN
    RETURN;
  END IF;

  v_club := nullif(btrim(coalesce(p_club_short_name, '')), '');

  IF v_club IS NOT NULL AND public.club_holiday_allows_fixture_early(p_fixture_id, v_club) THEN
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

  v_active := public.competition_active_gpsl_month(v_fixture.season_id, now());

  IF v_active IS NOT NULL AND v_active = v_fixture.gpsl_month THEN
    RETURN;
  END IF;

  IF public.match_schedule_fixture_is_catch_up(p_fixture_id) AND v_active IS NOT NULL THEN
    RETURN;
  END IF;

  SELECT unlock_at, lock_at
  INTO v_unlock, v_lock
  FROM public.competition_season_calendar m
  WHERE m.season_id = v_fixture.season_id
    AND m.gpsl_month = v_fixture.gpsl_month;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No calendar window for GPSL %', public.competition_gpsl_month_label(v_fixture.gpsl_month);
  END IF;

  IF now() < v_unlock THEN
    RAISE EXCEPTION '% matches unlock at % UK (Fri 19:00 week)',
      public.competition_gpsl_month_label(v_fixture.gpsl_month),
      to_char(v_unlock AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI');
  END IF;

  RAISE EXCEPTION '% matches locked since % UK',
    public.competition_gpsl_month_label(v_fixture.gpsl_month),
    to_char(v_lock AT TIME ZONE 'Europe/London', 'Dy DD Mon YYYY HH24:MI');
END;
$function$;

-- ---------------------------------------------------------------------------
-- Catch-up reset (stale agreed time → re-schedule in current month)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fixture_catch_up_reset_schedule(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_opponent text;
  v_play_label text;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture not open for catch-up reschedule';
  END IF;

  IF NOT public.match_schedule_fixture_is_catch_up(p_fixture_id) THEN
    RAISE EXCEPTION 'This fixture is not a catch-up match';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Your club is not in this fixture';
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);

  IF v_kickoff IS NOT NULL
     AND v_kickoff >= now()
     AND public.match_schedule_kickoff_in_proposal_window(p_fixture_id, v_kickoff)
  THEN
    RAISE EXCEPTION 'Agreed kick-off is still valid — use the normal schedule page';
  END IF;

  PERFORM public.match_schedule_reset_to_unscheduled(p_fixture_id);

  v_opponent := public.competition_fixture_opponent(p_fixture_id, v_club);
  v_play_label := public.competition_gpsl_month_label(v_fixture.gpsl_month);

  PERFORM public.match_schedule_notify_opponent(
    v_fixture,
    'match_rescheduled',
    format('Catch-up — %s fixture reopened', v_play_label),
    public.club_display_name(v_club)
      || format(' reset scheduling for this overdue %s fixture. Propose a new kick-off in the current GPSL month.', v_play_label),
    v_opponent,
    'catchup_reset:' || p_fixture_id::text || ':' || v_club
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Fixture context — catch-up fields
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
  v_prop_unlock timestamptz;
  v_prop_lock timestamptz;
  v_prop_month text;
  v_prop_catch_up boolean := false;
  v_is_catch_up boolean := false;
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

  v_is_catch_up := public.match_schedule_fixture_is_catch_up(p_fixture_id);
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

  SELECT w.unlock_at, w.lock_at, w.gpsl_month, w.is_catch_up
  INTO v_prop_unlock, v_prop_lock, v_prop_month, v_prop_catch_up
  FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w;

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

  IF v_is_catch_up AND v_fixture.status = 'scheduled' THEN
    v_can_catch_up_reset := (
      v_status IN ('agreed', 'negotiating')
      AND (
        v_kickoff IS NULL
        OR v_kickoff < now()
        OR NOT public.match_schedule_kickoff_in_proposal_window(p_fixture_id, v_kickoff)
      )
      AND v_override.id IS NULL
    );
  END IF;

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
      'division', v_fixture.division,
      'cup_code', v_fixture.cup_code,
      'home_club_short_name', v_home,
      'away_club_short_name', v_away,
      'status', v_fixture.status,
      'competition_type', v_fixture.competition_type,
      'is_forfeit', v_fixture.is_forfeit,
      'is_catch_up', v_is_catch_up
    ),
    'schedule', jsonb_build_object(
      'status', v_status,
      'agreed_kickoff_at', v_agreed,
      'home_proposal_count', v_home_count,
      'away_proposal_count', v_away_count,
      'discord_hint_shown', v_discord_hint,
      'mutual_override_used', v_mutual_used,
      'response_due_at', CASE WHEN v_schedule_found THEN v_schedule.response_due_at ELSE NULL END,
      'response_required_club_short_name', CASE WHEN v_schedule_found THEN v_schedule.response_required_club_short_name ELSE NULL END,
      'response_miss_count', CASE WHEN v_schedule_found THEN coalesce(v_schedule.response_miss_count, 0) ELSE 0 END
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
    'is_catch_up', v_is_catch_up,
    'month_window', jsonb_build_object('unlock_at', v_unlock, 'lock_at', v_lock),
    'proposal_window', jsonb_build_object(
      'unlock_at', v_prop_unlock,
      'lock_at', v_prop_lock,
      'gpsl_month', v_prop_month,
      'is_catch_up', coalesce(v_prop_catch_up, false)
    ),
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
    'response_deadline', public.match_schedule_response_deadline_json(p_fixture_id, v_club),
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
        AND NOT v_is_catch_up
      ),
      'can_emergency_drop', (
        v_fixture.status = 'scheduled'
        AND v_kickoff IS NOT NULL
        AND now() < v_kickoff
        AND now() > v_kickoff - interval '24 hours'
        AND v_override.id IS NULL
        AND NOT v_is_catch_up
      ),
      'can_catch_up_reset', v_can_catch_up_reset
    )
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Fixtures public view — is_catch_up column
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.competition_cup_qualified_public;
DROP VIEW IF EXISTS public.competition_cup_bracket_public;
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
  COALESCE(sch.status, 'unscheduled') AS schedule_status,
  sch.agreed_kickoff_at,
  sch.pending_proposal_id AS schedule_pending_proposal_id,
  sch.home_proposal_count AS schedule_home_proposal_count,
  sch.away_proposal_count AS schedule_away_proposal_count,
  COALESCE(sch.discord_hint_shown, false) AS schedule_discord_hint,
  chk.home_checked_in,
  chk.away_checked_in
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
    AND rs.status = 'pending'
    AND (
      public.is_gpsl_admin()
      OR public.my_club_shortname() = f.home_club_short_name
      OR public.my_club_shortname() = f.away_club_short_name
    )
  LIMIT 1
) sub ON true
WHERE s.status = 'active' AND s.is_current = true;

CREATE VIEW public.competition_cup_bracket_public
WITH (security_invoker = false)
AS
SELECT
  n.id,
  n.season_id,
  n.cup_code,
  n.round_no,
  n.match_no,
  n.cup_leg,
  n.leg1_node_id,
  sch.round_label,
  sch.gpsl_month AS round_gpsl_month,
  n.home_club_short_name,
  hc."Club" AS home_club_name,
  n.away_club_short_name,
  ac."Club" AS away_club_name,
  n.winner_club_short_name,
  wc."Club" AS winner_club_name,
  n.fixture_id,
  f.status AS fixture_status,
  f.home_goals,
  f.away_goals,
  f.gpsl_month AS fixture_gpsl_month,
  f.weather,
  f.pitch_condition,
  f.kit_season,
  public.competition_club_continent(n.home_club_short_name) AS home_continent,
  n.child_node_id,
  n.child_slot
FROM public.competition_cup_bracket_nodes n
JOIN public.competition_seasons s ON s.id = n.season_id
LEFT JOIN public.competition_cup_round_schedule sch
  ON sch.cup_code = n.cup_code
 AND sch.round_no = n.round_no
 AND sch.cup_leg = coalesce(n.cup_leg, 1)
LEFT JOIN public."Clubs" hc ON hc."ShortName" = n.home_club_short_name
LEFT JOIN public."Clubs" ac ON ac."ShortName" = n.away_club_short_name
LEFT JOIN public."Clubs" wc ON wc."ShortName" = n.winner_club_short_name
LEFT JOIN public.competition_fixtures f ON f.id = n.fixture_id
WHERE s.status = 'active' AND s.is_current = true;

CREATE VIEW public.competition_cup_qualified_public
WITH (security_invoker = false)
AS
SELECT s.id AS season_id, cup.cup_code, q.club_short_name
FROM public.competition_seasons s
CROSS JOIN (VALUES ('super8'), ('plate'), ('shield'), ('spoon'), ('league_cup')) AS cup(cup_code)
CROSS JOIN LATERAL unnest(public.competition_qualify_cup_clubs(s.id, cup.cup_code)) AS q(club_short_name)
WHERE s.is_current = true AND s.status = 'active';

GRANT SELECT ON public.competition_fixtures_public TO authenticated;
GRANT SELECT ON public.competition_fixtures_public TO anon;
GRANT SELECT ON public.competition_cup_bracket_public TO authenticated;
GRANT SELECT ON public.competition_cup_bracket_public TO anon;
GRANT SELECT ON public.competition_cup_qualified_public TO authenticated;

GRANT EXECUTE ON FUNCTION public.match_schedule_fixture_is_catch_up(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fixture_catch_up_reset_schedule(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
