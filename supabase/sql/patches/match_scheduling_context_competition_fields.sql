-- Adds division/cup_code to match_schedule_fixture_context

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
      'division', v_fixture.division,
      'cup_code', v_fixture.cup_code,
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

NOTIFY pgrst, 'reload schema';
