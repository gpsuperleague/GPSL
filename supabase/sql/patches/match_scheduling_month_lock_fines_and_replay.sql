-- =============================================================================
-- Match scheduling — month-lock response fines + within-month replay reset
-- =============================================================================
-- Run after: match_scheduling_response_deadline_first_after_unlock.sql,
--            match_scheduling_catch_up.sql, free_tier_cron_throttle.sql (optional)
--
-- Policy:
--   • Response-deadline FINES only when a fixture's play GPSL month locks
--     (not on every cron tick during the month). In-month: track misses only.
--   • Fixtures stay playable for the whole play month: if agreed kick-off
--     passed with no check-ins, either club can reset and pick a new time
--     without waiting for catch-up (after month closes).
-- =============================================================================

DROP FUNCTION IF EXISTS public.match_schedule_notify_opponent(
  public.competition_fixtures,
  text,
  text,
  text,
  text,
  text
);

CREATE OR REPLACE FUNCTION public.match_schedule_fixture_play_month_open(p_fixture_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT NOT public.match_schedule_fixture_play_month_closed(p_fixture_id);
$$;

-- ---------------------------------------------------------------------------
-- During month: track overdue responses (extend deadline) — no fines
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_process_scheduling_response_deadlines(
  p_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_miss_num smallint;
  v_count int := 0;
BEGIN
  FOR v_row IN
    SELECT
      s.fixture_id,
      s.pending_proposal_id,
      s.response_due_at,
      s.response_miss_count
    FROM public.competition_fixture_schedule s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE f.season_id = p_season_id
      AND f.competition_type = 'league'
      AND f.status = 'scheduled'
      AND s.status = 'negotiating'
      AND s.pending_proposal_id IS NOT NULL
      AND s.response_due_at IS NOT NULL
      AND s.response_required_club_short_name IS NOT NULL
      AND s.response_due_at < now()
      AND public.match_schedule_fixture_play_month_open(f.id)
      AND EXISTS (
        SELECT 1
        FROM public.competition_fixture_schedule_proposal p
        WHERE p.id = s.pending_proposal_id
          AND p.status = 'pending'
      )
  LOOP
    v_miss_num := coalesce(v_row.response_miss_count, 0) + 1;

    UPDATE public.competition_fixture_schedule
    SET
      response_due_at = response_due_at + interval '24 hours',
      response_miss_count = v_miss_num,
      updated_at = now()
    WHERE fixture_id = v_row.fixture_id;

    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'misses_tracked', v_count,
    'fines_deferred', true
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- At play-month lock: apply response fines (once per fixture per month lock)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_enforce_scheduling_response_fines(
  p_season_id bigint,
  p_closed_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_lock timestamptz;
  v_note_key text;
  v_note_body text;
  v_apply jsonb;
  v_fined jsonb := '[]'::jsonb;
  v_count int := 0;
  v_skipped int := 0;
BEGIN
  SELECT c.lock_at
  INTO v_lock
  FROM public.competition_season_calendar c
  WHERE c.season_id = p_season_id
    AND c.gpsl_month = p_closed_gpsl_month;

  IF v_lock IS NULL OR v_lock > now() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'month_not_closed',
      'closed_gpsl_month', p_closed_gpsl_month
    );
  END IF;

  FOR v_row IN
    SELECT
      s.fixture_id,
      s.pending_proposal_id,
      s.response_required_club_short_name,
      s.response_miss_count,
      f.gpsl_month,
      f.matchday
    FROM public.competition_fixture_schedule s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE f.season_id = p_season_id
      AND f.competition_type = 'league'
      AND f.status = 'scheduled'
      AND f.gpsl_month = p_closed_gpsl_month
      AND s.status = 'negotiating'
      AND s.pending_proposal_id IS NOT NULL
      AND s.response_required_club_short_name IS NOT NULL
      AND (
        coalesce(s.response_miss_count, 0) > 0
        OR (
          s.response_due_at IS NOT NULL
          AND s.response_due_at < v_lock
        )
      )
      AND EXISTS (
        SELECT 1
        FROM public.competition_fixture_schedule_proposal p
        WHERE p.id = s.pending_proposal_id
          AND p.status = 'pending'
      )
      AND EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE c."ShortName" = s.response_required_club_short_name
          AND c.owner_id IS NOT NULL
      )
  LOOP
    v_note_key := format(
      'sched_response_lock:%s:%s',
      p_closed_gpsl_month,
      v_row.fixture_id
    );

    IF EXISTS (
      SELECT 1
      FROM public.competition_fine_applied fa
      WHERE fa.fixture_id = v_row.fixture_id
        AND fa.tariff_code = 'match_response_deadline'
        AND fa.note LIKE v_note_key || '%'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_note_body := format(
      '%s|Response deadline missed · %s fixture · MD%s · assessed at month lock (misses tracked: %s)',
      v_note_key,
      public.competition_gpsl_month_label(v_row.gpsl_month),
      v_row.matchday,
      coalesce(v_row.response_miss_count, 0)
    );

    v_apply := public.competition_apply_club_fine_tariff(
      v_row.response_required_club_short_name,
      'match_response_deadline',
      NULL,
      v_note_body,
      v_row.fixture_id,
      p_season_id
    );

    v_count := v_count + 1;
    v_fined := v_fined || jsonb_build_array(
      jsonb_build_object(
        'fixture_id', v_row.fixture_id,
        'club', v_row.response_required_club_short_name,
        'apply', v_apply
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'closed_gpsl_month', p_closed_gpsl_month,
    'fines_applied', v_count,
    'skipped', v_skipped,
    'fined', v_fined
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_process_scheduling_response_fines(
  p_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cal record;
  v_job_key text;
  v_res jsonb;
  v_results jsonb := '[]'::jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_season_calendar_config c
    WHERE c.season_id = p_season_id
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_calendar');
  END IF;

  FOR v_cal IN
    SELECT c.gpsl_month, c.lock_at
    FROM public.competition_season_calendar c
    WHERE c.season_id = p_season_id
      AND c.lock_at IS NOT NULL
      AND c.lock_at <= now()
    ORDER BY public.competition_gpsl_month_sort(c.gpsl_month)
  LOOP
    v_job_key := 'scheduling_response_fines:' || v_cal.gpsl_month;

    IF EXISTS (
      SELECT 1
      FROM public.competition_season_calendar_jobs j
      WHERE j.season_id = p_season_id
        AND j.job_key = v_job_key
    ) THEN
      CONTINUE;
    END IF;

    v_res := public.competition_enforce_scheduling_response_fines(
      p_season_id,
      v_cal.gpsl_month
    );

    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      p_season_id,
      v_job_key,
      v_cal.gpsl_month,
      coalesce(v_res, '{}'::jsonb)
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result,
          gpsl_month = excluded.gpsl_month,
          ran_at = now();

    v_results := v_results || jsonb_build_array(
      jsonb_build_object(
        'gpsl_month', v_cal.gpsl_month,
        'result', v_res
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'processed', v_results
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Replay reset: stale agreed kick-off while play month still open
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
  v_is_catch_up boolean;
  v_play_month_open boolean;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture not open for reschedule';
  END IF;

  v_is_catch_up := public.match_schedule_fixture_is_catch_up(p_fixture_id);
  v_play_month_open := public.match_schedule_fixture_play_month_open(p_fixture_id);

  IF NOT v_is_catch_up AND NOT v_play_month_open THEN
    RAISE EXCEPTION 'Play month has closed — use catch-up when available';
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

  IF NOT v_is_catch_up AND (v_kickoff IS NULL OR v_kickoff >= now()) THEN
    RAISE EXCEPTION 'Replay reset is only for a past agreed kick-off in the current play month';
  END IF;

  PERFORM public.match_schedule_reset_to_unscheduled(p_fixture_id);

  v_opponent := public.competition_fixture_opponent(p_fixture_id, v_club);
  v_play_label := public.competition_gpsl_month_label(v_fixture.gpsl_month);

  PERFORM public.match_schedule_notify_opponent(
    v_fixture,
    'match_rescheduled',
    CASE
      WHEN v_is_catch_up THEN format('Catch-up — %s fixture reopened', v_play_label)
      ELSE format('Replay — %s fixture reopened', v_play_label)
    END,
    public.club_display_name(v_club)
      || CASE
        WHEN v_is_catch_up THEN format(
          ' reset scheduling for this overdue %s fixture. Propose a new kick-off in the current GPSL month.',
          v_play_label
        )
        ELSE format(
          ' reset scheduling after a missed kick-off. Home proposes a new time in the %s play window.',
          v_play_label
        )
      END,
    v_opponent,
    CASE
      WHEN v_is_catch_up THEN 'catchup_reset:' || p_fixture_id::text || ':' || v_club
      ELSE 'replay_reset:' || p_fixture_id::text || ':' || v_club
    END,
    NULL::bigint
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Calendar month tick — response fines at month lock; in-month = track only
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_calendar_month_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text;
  v_month_sort smallint;
  v_august_sort constant smallint := public.competition_gpsl_month_sort('august');
  v_job_id bigint;
  v_enforcement jsonb;
  v_totm jsonb;
  v_sched_fines jsonb;
  v_response_track jsonb;
  v_response_fines jsonb;
  v_out jsonb;
  v_last_scheduling timestamptz;
  v_run_scheduling boolean := false;
BEGIN
  SELECT id
  INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
    AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_season');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.competition_season_calendar_config c
    WHERE c.season_id = v_season_id
  ) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'no_calendar',
      'season_id', v_season_id
    );
  END IF;

  v_month := public.competition_active_gpsl_month(v_season_id, now());
  v_month_sort := public.competition_gpsl_month_sort(v_month);

  v_out := jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'gpsl_month', v_month,
    'calendar_phase', CASE
      WHEN v_month IS NULL THEN 'between_months'
      ELSE 'in_month'
    END
  );

  IF to_regprocedure('public.competition_process_month_team_awards(bigint)') IS NOT NULL THEN
    v_totm := public.competition_process_month_team_awards(v_season_id);
    v_out := v_out || jsonb_build_object('team_of_month', v_totm);
  END IF;

  SELECT j.ran_at
  INTO v_last_scheduling
  FROM public.competition_season_calendar_jobs j
  WHERE j.season_id = v_season_id
    AND j.job_key = 'scheduling_enforcement_throttle'
  LIMIT 1;

  v_run_scheduling :=
    v_last_scheduling IS NULL
    OR v_last_scheduling < now() - interval '5 minutes';

  IF v_run_scheduling THEN
    v_response_track := public.competition_process_scheduling_response_deadlines(v_season_id);
    v_out := v_out || jsonb_build_object('scheduling_response_deadlines', v_response_track);

    v_sched_fines := public.competition_process_scheduling_arrangement_fines(v_season_id);
    v_out := v_out || jsonb_build_object('scheduling_arrangement_fines', v_sched_fines);

    v_response_fines := public.competition_process_scheduling_response_fines(v_season_id);
    v_out := v_out || jsonb_build_object('scheduling_response_fines', v_response_fines);

    INSERT INTO public.competition_season_calendar_jobs (
      season_id, job_key, gpsl_month, result
    )
    VALUES (
      v_season_id,
      'scheduling_enforcement_throttle',
      coalesce(v_month, 'none'),
      jsonb_build_object('ok', true, 'ran_at', now())
    )
    ON CONFLICT (season_id, job_key) DO UPDATE
      SET result = excluded.result,
          gpsl_month = excluded.gpsl_month,
          ran_at = now();
  ELSE
    v_out := v_out || jsonb_build_object(
      'scheduling_response_deadlines', jsonb_build_object('skipped', true, 'reason', 'throttled'),
      'scheduling_arrangement_fines', jsonb_build_object('skipped', true, 'reason', 'throttled'),
      'scheduling_response_fines', jsonb_build_object('skipped', true, 'reason', 'throttled')
    );
  END IF;

  IF v_month IS NULL OR v_month_sort IS NULL OR v_month_sort < v_august_sort THEN
    RETURN v_out || jsonb_build_object(
      'squad_minimum_august', jsonb_build_object('skipped', true, 'reason', 'before_august')
    );
  END IF;

  INSERT INTO public.competition_season_calendar_jobs (
    season_id, job_key, gpsl_month, result
  )
  VALUES (
    v_season_id,
    'squad_minimum_august',
    v_month,
    jsonb_build_object('status', 'running')
  )
  ON CONFLICT (season_id, job_key) DO NOTHING
  RETURNING id INTO v_job_id;

  IF v_job_id IS NULL THEN
    RETURN v_out || jsonb_build_object(
      'squad_minimum_august', jsonb_build_object('skipped', true, 'reason', 'already_ran')
    );
  END IF;

  v_enforcement := public.competition_enforce_squad_minimum_august(v_season_id);

  UPDATE public.competition_season_calendar_jobs
  SET result = v_enforcement,
      gpsl_month = v_month,
      ran_at = now()
  WHERE id = v_job_id;

  RETURN v_out || jsonb_build_object('squad_minimum_august', v_enforcement);
END;
$function$;

-- Fixture context — expose replay reset during open play month
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
  v_can_replay_reset boolean := false;
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
  SELECT w.unlock_at, w.lock_at, w.gpsl_month, w.is_catch_up
  INTO v_prop_unlock, v_prop_lock, v_prop_month, v_prop_catch_up
  FROM public.match_schedule_proposal_kickoff_window(p_fixture_id) w;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('iso_dow', s.iso_dow, 'hour', s.slot_minute / 60, 'minute', s.slot_minute % 60) ORDER BY s.iso_dow, s.slot_minute), '[]'::jsonb)
  INTO v_slots FROM public.club_owner_availability_slot s
  WHERE s.season_id = v_fixture.season_id AND s.club_short_name = v_club;
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
  IF v_fixture.status = 'scheduled' AND v_status = 'agreed' AND v_agreed IS NOT NULL AND NOT v_mutual_used AND v_override.id IS NULL THEN
    BEGIN
      v_play_now_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);
      v_can_play_now := true;
    EXCEPTION WHEN OTHERS THEN
      v_can_play_now := false; v_play_now_kickoff := NULL;
    END;
    v_can_mutual_new_time := now() < v_agreed;
  END IF;
  IF v_override.id IS NOT NULL AND v_club IS NOT NULL THEN
    IF v_club = v_home THEN v_my_override_confirmed := v_override.home_confirmed_at IS NOT NULL;
    ELSE v_my_override_confirmed := v_override.away_confirmed_at IS NOT NULL; END IF;
    v_can_confirm_override := NOT v_my_override_confirmed AND v_override.requested_by_club <> v_club;
    v_can_cancel_override := v_my_override_confirmed OR v_override.requested_by_club = v_club;
  END IF;
  RETURN jsonb_build_object(
    'fixture', jsonb_build_object('id', v_fixture.id, 'gpsl_month', v_fixture.gpsl_month, 'division', v_fixture.division, 'cup_code', v_fixture.cup_code, 'home_club_short_name', v_home, 'away_club_short_name', v_away, 'status', v_fixture.status, 'competition_type', v_fixture.competition_type, 'is_forfeit', v_fixture.is_forfeit, 'is_catch_up', v_is_catch_up),
    'schedule', jsonb_build_object('status', v_status, 'agreed_kickoff_at', v_agreed, 'home_proposal_count', v_home_count, 'away_proposal_count', v_away_count, 'discord_hint_shown', v_discord_hint, 'mutual_override_used', v_mutual_used, 'response_due_at', CASE WHEN v_schedule_found THEN v_schedule.response_due_at ELSE NULL END, 'response_required_club_short_name', CASE WHEN v_schedule_found THEN v_schedule.response_required_club_short_name ELSE NULL END, 'response_miss_count', CASE WHEN v_schedule_found THEN coalesce(v_schedule.response_miss_count, 0) ELSE 0 END),
    'pending_proposal', CASE WHEN v_pending.id IS NULL THEN NULL ELSE jsonb_build_object('id', v_pending.id, 'proposed_by_club_short_name', v_pending.proposed_by_club_short_name, 'kickoff_at', v_pending.kickoff_at) END,
    'mutual_override', CASE WHEN v_override.id IS NULL THEN NULL ELSE jsonb_build_object('id', v_override.id, 'kind', v_override.kind, 'proposed_kickoff_at', v_override.proposed_kickoff_at, 'requested_by_club_short_name', v_override.requested_by_club, 'expires_at', v_override.expires_at, 'my_confirmed', v_my_override_confirmed, 'can_confirm', v_can_confirm_override, 'can_cancel', v_can_cancel_override) END,
    'my_role', v_role, 'is_catch_up', v_is_catch_up,
    'month_window', jsonb_build_object('unlock_at', v_unlock, 'lock_at', v_lock),
    'proposal_window', jsonb_build_object('unlock_at', v_prop_unlock, 'lock_at', v_prop_lock, 'gpsl_month', v_prop_month, 'is_catch_up', coalesce(v_prop_catch_up, false)),
    'my_timezone', public.match_schedule_club_timezone(v_club),
    'home_timezone', public.match_schedule_club_timezone(v_home),
    'away_timezone', public.match_schedule_club_timezone(v_away),
    'my_weekly_slots', v_slots,
    'intersection_slots', (SELECT COALESCE(jsonb_agg(i.kickoff_at ORDER BY i.kickoff_at), '[]'::jsonb) FROM public.match_schedule_intersection_slots(p_fixture_id) i),
    'can_propose_first', (v_role = 'home' AND v_status = 'unscheduled' AND v_fixture.status = 'scheduled'),
    'can_respond', (v_pending.id IS NOT NULL AND v_pending.proposed_by_club_short_name <> v_club AND v_status = 'negotiating'),
    'response_deadline', public.match_schedule_response_deadline_json(p_fixture_id, v_club),
    'mutual_override_options', jsonb_build_object('can_request_play_now', v_can_play_now, 'play_now_kickoff_at', v_play_now_kickoff, 'can_request_new_time', v_can_mutual_new_time),
    'checkin', jsonb_build_object('home_checked_in', v_home_in, 'away_checked_in', v_away_in, 'my_checked_in', v_my_in, 'window_opens_at', v_kickoff, 'window_closes_at', CASE WHEN v_kickoff IS NULL THEN NULL ELSE v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval END, 'play_block_ends_at', CASE WHEN v_kickoff IS NULL THEN NULL ELSE v_kickoff + (public.match_schedule_block_minutes() || ' minutes')::interval END, 'can_check_in', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() >= v_kickoff AND now() < v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval AND NOT v_my_in), 'can_play', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND v_home_in AND v_away_in AND now() >= v_kickoff AND now() < v_kickoff + (public.match_schedule_block_minutes() || ' minutes')::interval)),
    'allowances', jsonb_build_object('emergency_drops_used', v_emergency_used, 'emergency_drops_remaining', greatest(0, 2 - v_emergency_used), 'reschedule_used_this_month', v_reschedule_used, 'can_voluntary_drop', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() <= v_kickoff - interval '24 hours' AND NOT v_reschedule_used AND v_override.id IS NULL AND NOT v_is_catch_up), 'can_emergency_drop', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() < v_kickoff AND now() > v_kickoff - interval '24 hours' AND v_override.id IS NULL AND NOT v_is_catch_up), 'can_catch_up_reset', v_can_catch_up_reset, 'can_replay_reset', v_can_replay_reset)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_enforce_scheduling_response_fines(bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.competition_process_scheduling_response_fines(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.match_schedule_fixture_play_month_open(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
