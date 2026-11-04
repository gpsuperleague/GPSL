-- =============================================================================
-- Check-in miss: keep punishments + dual path (enter result OR reschedule)
-- (2026-11-04)
--
-- After check-in window closes:
--   • One checked in → checked-in club may submit; misser punished (as now)
--   • Neither checked in → BOTH punished, but KEEP agreed KO (no auto-clear)
--     and EITHER club may submit the result
--   • Either way, Pick new time / catch-up reset remains available
--   • Pending result blocks reschedule until confirmed/rejected
--
-- Also: only bump play_attempt when a new no-show event is recorded (idempotent).
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Both-miss: punish but keep KO; onesided: idempotent bump
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fixture_try_checkin_forfeit(p_fixture_id bigint)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_window_end timestamptz;
  v_home_in boolean;
  v_away_in boolean;
  v_loser text;
  v_winner text;
  v_attempt integer := 1;
  v_manual boolean := false;
  v_home_res jsonb;
  v_away_res jsonb;
  v_one_res jsonb;
  v_new_event boolean := false;
BEGIN
  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND OR v_fixture.status <> 'scheduled' THEN
    RETURN false;
  END IF;

  PERFORM public.match_schedule_clear_no_show_if_played(p_fixture_id);

  IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL THEN
    v_manual := public.fixture_is_manual_black_box(p_fixture_id);
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    PERFORM public.match_schedule_clear_no_show(p_fixture_id);
    RETURN false;
  END IF;

  v_window_end := v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval;
  IF now() < v_window_end THEN
    RETURN false;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_fixture.home_club_short_name
  ) INTO v_home_in;
  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id AND c.club_short_name = v_fixture.away_club_short_name
  ) INTO v_away_in;

  IF v_home_in AND v_away_in THEN
    PERFORM public.match_schedule_clear_no_show(p_fixture_id);
    RETURN false;
  END IF;

  -- Manual black-box: no GPSL check-in ladder (result entry anytime)
  IF v_manual THEN
    RETURN false;
  END IF;

  SELECT coalesce(s.play_attempt_count, 1) INTO v_attempt
  FROM public.competition_fixture_schedule s WHERE s.fixture_id = p_fixture_id;
  IF v_attempt < 1 THEN v_attempt := 1; END IF;

  -- Both missed: fines/strikes stay; KEEP agreed kick-off so owners can
  -- enter a result (match was played) OR pick a new time.
  IF NOT v_home_in AND NOT v_away_in THEN
    v_home_res := public.match_schedule_apply_club_noshow(
      p_fixture_id, v_fixture.home_club_short_name, v_kickoff, v_attempt, true
    );
    v_away_res := public.match_schedule_apply_club_noshow(
      p_fixture_id, v_fixture.away_club_short_name, v_kickoff, v_attempt, true
    );
    v_new_event := NOT (
      coalesce((v_home_res->>'deduped')::boolean, false)
      AND coalesce((v_away_res->>'deduped')::boolean, false)
    );
    IF v_new_event THEN
      PERFORM public.match_schedule_bump_attempt_on_noshow(p_fixture_id);
    END IF;

    PERFORM public.match_schedule_clear_no_show(p_fixture_id);

    UPDATE public.competition_fixture_schedule s
    SET admin_result_unlock_at = coalesce(s.admin_result_unlock_at, now()),
        admin_result_unlock_note = coalesce(
          s.admin_result_unlock_note,
          'both_miss_auto: either club may submit or reschedule; fines/strikes kept'
        ),
        updated_at = now()
    WHERE s.fixture_id = p_fixture_id;

    RETURN true;
  END IF;

  -- One-sided miss
  IF v_home_in AND NOT v_away_in THEN
    v_loser := v_fixture.away_club_short_name;
    v_winner := v_fixture.home_club_short_name;
  ELSE
    v_loser := v_fixture.home_club_short_name;
    v_winner := v_fixture.away_club_short_name;
  END IF;

  UPDATE public.competition_fixture_schedule
  SET no_show_club_short_name = v_loser,
      no_show_kickoff_at = v_kickoff,
      updated_at = now()
  WHERE fixture_id = p_fixture_id;

  v_one_res := public.match_schedule_apply_club_noshow(
    p_fixture_id, v_loser, v_kickoff, v_attempt, false
  );

  -- Only bump attempt when a new no-show event was recorded (not on every poll)
  IF coalesce((v_one_res->>'ok')::boolean, false)
     AND NOT coalesce((v_one_res->>'deduped')::boolean, false)
     AND NOT coalesce((v_one_res->>'skipped')::boolean, false)
     AND EXISTS (
       SELECT 1 FROM public.competition_fixtures f
       WHERE f.id = p_fixture_id AND f.status = 'scheduled'
     )
  THEN
    PERFORM public.match_schedule_bump_attempt_on_noshow(p_fixture_id);
  END IF;

  UPDATE public.competition_fixture_schedule s
  SET admin_result_unlock_at = coalesce(s.admin_result_unlock_at, now()),
      admin_result_unlock_note = coalesce(
        s.admin_result_unlock_note,
        format(
          'onesided_checkin_auto: %s may submit or either may reschedule; %s missed check-in',
          upper(v_winner),
          upper(v_loser)
        )
      ),
      updated_at = now()
  WHERE s.fixture_id = p_fixture_id;

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.fixture_try_checkin_forfeit(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fixture_try_checkin_forfeit(bigint)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.fixture_try_checkin_forfeit(bigint) IS
  'After check-in window: apply no-show fines/strikes. Onesided keeps KO (checked-in may submit). Both-miss keeps KO (either may submit). Reschedule remains available. Attempt bump is idempotent per kick-off.';

-- ---------------------------------------------------------------------------
-- 2) Result entry gate: both-miss → either may submit after window
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_schedule_assert_ready_to_play(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_kickoff timestamptz;
  v_window_end timestamptz;
  v_home_in boolean;
  v_away_in boolean;
  v_club text;
  v_checked text;
  v_missed text;
BEGIN
  IF public.is_gpsl_admin() THEN
    RETURN;
  END IF;

  IF to_regprocedure('public.fixture_try_checkin_forfeit(bigint)') IS NOT NULL THEN
    PERFORM public.fixture_try_checkin_forfeit(p_fixture_id);
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = p_fixture_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_fixture.status = 'played' THEN
    RAISE EXCEPTION 'This fixture has already been played';
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture is not open for result entry';
  END IF;

  IF to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
     AND public.fixture_is_manual_black_box(p_fixture_id) THEN
    RETURN;
  END IF;

  v_kickoff := public.match_schedule_agreed_kickoff(p_fixture_id);
  IF v_kickoff IS NULL THEN
    RAISE EXCEPTION 'Kick-off time must be agreed before entering a result';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.home_club_short_name
  ) INTO v_home_in;

  SELECT EXISTS (
    SELECT 1 FROM public.competition_fixture_checkin c
    WHERE c.fixture_id = p_fixture_id
      AND c.club_short_name = v_fixture.away_club_short_name
  ) INTO v_away_in;

  IF v_home_in AND v_away_in THEN
    NULL; -- normal path
  ELSIF (v_home_in AND NOT v_away_in) OR (v_away_in AND NOT v_home_in) THEN
    v_window_end :=
      v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval;
    IF now() < v_window_end THEN
      RAISE EXCEPTION 'Both clubs must check in before entering a result';
    END IF;

    BEGIN
      v_club := upper(nullif(btrim(public.my_club_shortname()), ''));
    EXCEPTION
      WHEN OTHERS THEN
        v_club := NULL;
    END;

    IF v_club IS NULL THEN
      RAISE EXCEPTION 'No club linked to this account';
    END IF;

    IF v_home_in THEN
      v_checked := upper(v_fixture.home_club_short_name);
      v_missed := upper(v_fixture.away_club_short_name);
    ELSE
      v_checked := upper(v_fixture.away_club_short_name);
      v_missed := upper(v_fixture.home_club_short_name);
    END IF;

    IF v_club <> v_checked THEN
      RAISE EXCEPTION
        'You missed check-in — only % can submit the result (your no-show penalty still applies)',
        v_checked;
    END IF;

    UPDATE public.competition_fixture_schedule s
    SET admin_result_unlock_at = coalesce(s.admin_result_unlock_at, now()),
        admin_result_unlock_note = coalesce(
          s.admin_result_unlock_note,
          format(
            'onesided_checkin_auto: %s may submit; %s missed check-in',
            v_checked,
            v_missed
          )
        ),
        updated_at = now()
    WHERE s.fixture_id = p_fixture_id;
  ELSIF NOT v_home_in AND NOT v_away_in THEN
    v_window_end :=
      v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval;
    IF now() < v_window_end THEN
      RAISE EXCEPTION 'Both clubs must check in before entering a result';
    END IF;

    BEGIN
      v_club := upper(nullif(btrim(public.my_club_shortname()), ''));
    EXCEPTION
      WHEN OTHERS THEN
        v_club := NULL;
    END;

    IF v_club IS NULL THEN
      RAISE EXCEPTION 'No club linked to this account';
    END IF;

    IF v_club NOT IN (
         upper(v_fixture.home_club_short_name),
         upper(v_fixture.away_club_short_name)
       )
    THEN
      RAISE EXCEPTION 'Your club is not in this fixture';
    END IF;

    UPDATE public.competition_fixture_schedule s
    SET admin_result_unlock_at = coalesce(s.admin_result_unlock_at, now()),
        admin_result_unlock_note = coalesce(
          s.admin_result_unlock_note,
          'both_miss_auto: either club may submit; fines/strikes kept'
        ),
        updated_at = now()
    WHERE s.fixture_id = p_fixture_id;
  ELSE
    RAISE EXCEPTION 'Both clubs must check in before entering a result';
  END IF;

  IF NOT public.match_schedule_result_month_allows_submit(p_fixture_id) THEN
    RAISE EXCEPTION
      'Result entry is closed for this fixture until its GPSL month (or a later month) is open';
  END IF;
END;
$function$;

COMMENT ON FUNCTION public.match_schedule_assert_ready_to_play(bigint) IS
  'Result entry gate: both check-ins, or after window onesided (checked-in only) / both-miss (either). No-show penalties still apply.';

GRANT EXECUTE ON FUNCTION public.match_schedule_assert_ready_to_play(bigint)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3) Block pick-new-time while a result is pending confirmation
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

  IF EXISTS (
    SELECT 1
    FROM public.competition_result_submissions s
    WHERE s.fixture_id = p_fixture_id
      AND s.status = 'pending'
  ) THEN
    RAISE EXCEPTION
      'A result is pending confirmation — confirm or reject it before picking a new time';
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
    END
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.fixture_catch_up_reset_schedule(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fixture_catch_up_reset_schedule(bigint)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.fixture_catch_up_reset_schedule(bigint) IS
  'Reset schedule after missed/past kick-off or catch-up. Blocked while a result submission is pending.';

-- ---------------------------------------------------------------------------
-- 4) Schedule context
-- ---------------------------------------------------------------------------
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
  v_play_now_reason text;
  v_play_now_json jsonb;
  v_can_play_now boolean := false;
  v_can_mutual_new_time boolean := false;
  v_my_override_confirmed boolean := false;
  v_can_confirm_override boolean := false;
  v_can_cancel_override boolean := false;
  v_can_catch_up_reset boolean := false;
  v_can_replay_reset boolean := false;
  v_result_pending boolean := false;
  v_miss_choice text := NULL;
  v_can_enter_result boolean := false;
  v_window_closed boolean := false;
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
  v_result_pending := EXISTS (
    SELECT 1 FROM public.competition_result_submissions rs
    WHERE rs.fixture_id = p_fixture_id AND rs.status = 'pending'
  );
  IF v_kickoff IS NOT NULL THEN
    v_window_closed := now() >= v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval;
  END IF;
  IF v_fixture.status = 'scheduled'
     AND v_kickoff IS NOT NULL
     AND v_window_closed
     AND NOT v_result_pending
     AND NOT (
       to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
       AND public.fixture_is_manual_black_box(p_fixture_id)
     )
  THEN
    IF v_home_in AND NOT v_away_in THEN
      IF v_club = v_home THEN v_miss_choice := 'onesided_checked';
      ELSIF v_club = v_away THEN v_miss_choice := 'onesided_missed'; END IF;
    ELSIF v_away_in AND NOT v_home_in THEN
      IF v_club = v_away THEN v_miss_choice := 'onesided_checked';
      ELSIF v_club = v_home THEN v_miss_choice := 'onesided_missed'; END IF;
    ELSIF NOT v_home_in AND NOT v_away_in THEN
      v_miss_choice := 'both_miss';
    END IF;
  END IF;
  v_can_enter_result :=
    (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND v_home_in AND v_away_in
      AND now() >= v_kickoff AND now() < v_kickoff + (public.match_schedule_block_minutes() || ' minutes')::interval
      AND NOT v_result_pending)
    OR (v_miss_choice IN ('onesided_checked', 'both_miss') AND coalesce(v_has_mgr, false) AND NOT v_result_pending);
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
  IF v_result_pending THEN
    v_can_replay_reset := false;
    v_can_catch_up_reset := false;
  END IF;
  -- Play now: available on any future agreed KO (not gated by mutual_override_used).
  -- Free mutual new-time: one-shot per fixture (mutual_override_used).
  IF v_fixture.status = 'scheduled' AND v_status = 'agreed' AND v_agreed IS NOT NULL AND v_override.id IS NULL THEN
    BEGIN
      IF to_regprocedure('public.match_schedule_play_now_status(bigint)') IS NOT NULL THEN
        v_play_now_json := public.match_schedule_play_now_status(p_fixture_id);
        v_can_play_now := coalesce((v_play_now_json->>'can_request')::boolean, false);
        v_play_now_kickoff := (v_play_now_json->>'kickoff_at')::timestamptz;
        v_play_now_reason := v_play_now_json->>'reason';
      ELSE
        v_can_play_now := true;
        BEGIN
          v_play_now_kickoff := public.match_schedule_play_now_kickoff(p_fixture_id);
        EXCEPTION WHEN OTHERS THEN
          v_play_now_kickoff := NULL;
        END;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_can_play_now := true; v_play_now_kickoff := NULL; v_play_now_reason := SQLERRM;
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
    'schedule', jsonb_build_object('status', v_status, 'agreed_kickoff_at', v_agreed, 'home_proposal_count', v_home_count, 'away_proposal_count', v_away_count, 'discord_hint_shown', v_discord_hint, 'mutual_override_used', v_mutual_used, 'response_due_at', CASE WHEN v_schedule_found THEN v_schedule.response_due_at ELSE NULL END, 'response_required_club_short_name', CASE WHEN v_schedule_found THEN v_schedule.response_required_club_short_name ELSE NULL END, 'response_miss_count', CASE WHEN v_schedule_found THEN coalesce(v_schedule.response_miss_count, 0) ELSE 0 END, 'play_attempt_count', CASE WHEN v_schedule_found THEN coalesce(v_schedule.play_attempt_count, 0) ELSE 0 END, 'open_play_active', CASE WHEN v_schedule_found THEN coalesce(v_schedule.open_play_active, false) ELSE false END, 'open_play_deadline_gpsl_month', CASE WHEN v_schedule_found THEN v_schedule.open_play_deadline_gpsl_month ELSE NULL END),
    'no_show_ladder', CASE WHEN to_regprocedure('public.match_schedule_no_show_ladder_json(bigint)') IS NOT NULL THEN public.match_schedule_no_show_ladder_json(p_fixture_id) ELSE NULL END,
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
    'opp_window_slots', (SELECT COALESCE(jsonb_agg(i.kickoff_at ORDER BY i.kickoff_at), '[]'::jsonb)
      FROM public.match_schedule_club_window_slots(
        p_fixture_id,
        CASE WHEN v_club = v_home THEN v_away ELSE v_home END
      ) i),
    'poke_allowed', public.match_schedule_allow_free_propose(p_fixture_id),
    'prior_proposed_kickoffs', (SELECT COALESCE(jsonb_agg(i.kickoff_at ORDER BY i.kickoff_at), '[]'::jsonb)
      FROM public.match_schedule_prior_proposed_kickoffs(p_fixture_id) i),
    'intersection_slots', (SELECT COALESCE(jsonb_agg(i.kickoff_at ORDER BY i.kickoff_at), '[]'::jsonb) FROM public.match_schedule_intersection_slots(p_fixture_id) i),
    'manual_black_box', (
      to_regprocedure('public.fixture_is_manual_black_box(bigint)') IS NOT NULL
      AND public.fixture_is_manual_black_box(p_fixture_id)
    ),
    'can_propose_first', (
      (v_role = 'home' OR public.match_schedule_club_opened_reschedule(p_fixture_id, v_club))
      AND v_status = 'unscheduled' AND v_fixture.status = 'scheduled' AND v_has_mgr
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
    'mutual_override_options', jsonb_build_object('can_request_play_now', v_can_play_now, 'play_now_kickoff_at', v_play_now_kickoff, 'can_request_new_time', v_can_mutual_new_time, 'play_now_block_reason', v_play_now_reason),
    'checkin', jsonb_build_object('home_checked_in', v_home_in, 'away_checked_in', v_away_in, 'my_checked_in', v_my_in, 'window_opens_at', public.match_schedule_checkin_opens_at(v_kickoff), 'window_closes_at', CASE WHEN v_kickoff IS NULL THEN NULL ELSE v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval END, 'play_block_ends_at', CASE WHEN v_kickoff IS NULL THEN NULL ELSE v_kickoff + (public.match_schedule_block_minutes() || ' minutes')::interval END, 'can_check_in', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() >= public.match_schedule_checkin_opens_at(v_kickoff) AND now() < v_kickoff + (public.match_schedule_checkin_minutes() || ' minutes')::interval AND NOT v_my_in AND v_has_mgr), 'can_play', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND v_home_in AND v_away_in AND now() >= v_kickoff AND now() < v_kickoff + (public.match_schedule_block_minutes() || ' minutes')::interval), 'can_enter_result', v_can_enter_result, 'miss_choice_mode', v_miss_choice, 'result_pending', v_result_pending, 'window_closed', v_window_closed),
    'allowances', jsonb_build_object('emergency_drops_used', v_emergency_used, 'emergency_drops_remaining', greatest(0, 2 - v_emergency_used), 'reschedule_used_this_month', v_reschedule_used, 'can_voluntary_drop', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() <= v_kickoff - interval '24 hours' AND NOT v_reschedule_used AND v_override.id IS NULL AND NOT v_is_catch_up), 'can_emergency_drop', (v_fixture.status = 'scheduled' AND v_kickoff IS NOT NULL AND now() < v_kickoff AND now() > v_kickoff - interval '24 hours' AND v_override.id IS NULL AND NOT v_is_catch_up), 'can_catch_up_reset', v_can_catch_up_reset, 'can_replay_reset', v_can_replay_reset)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_fixture_context(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_schedule_fixture_context(bigint)
  TO authenticated, service_role;

-- Verify
SELECT
  position('KEEP agreed' IN pg_get_functiondef('public.fixture_try_checkin_forfeit(bigint)'::regprocedure)) > 0
    OR position('both_miss_auto' IN pg_get_functiondef('public.fixture_try_checkin_forfeit(bigint)'::regprocedure)) > 0
    AS forfeit_keeps_ko,
  position('both_miss_auto' IN pg_get_functiondef('public.match_schedule_assert_ready_to_play(bigint)'::regprocedure)) > 0
    AS ready_allows_both_miss,
  position('pending confirmation' IN pg_get_functiondef('public.fixture_catch_up_reset_schedule(bigint)'::regprocedure)) > 0
    AS reset_blocks_pending,
  position('miss_choice_mode' IN pg_get_functiondef('public.match_schedule_fixture_context(bigint)'::regprocedure)) > 0
    AS context_miss_choice;

NOTIFY pgrst, 'reload schema';
