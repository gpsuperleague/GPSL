-- =============================================================================
-- Admin: full fixture wipe → scheduled / unscheduled (replay / catch-up)
--
-- Clears: videos, result, stats, submissions, fixture-linked finance,
--         suspensions/injuries sourced from the fixture, schedule, check-ins.
-- Rebuilds match-fitness streaks for both clubs when helper exists.
--
-- Confirm phrase (exact): RESET FIXTURE REPLAY
-- Safe re-run. Admin / postgres / service_role.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_fixture_reset_preview(
  p_fixture_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures%ROWTYPE;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'fixture_not_found');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', v_f.id,
    'season_id', v_f.season_id,
    'status', v_f.status,
    'competition_type', v_f.competition_type,
    'division', v_f.division,
    'cup_code', v_f.cup_code,
    'matchday', v_f.matchday,
    'gpsl_month', v_f.gpsl_month,
    'home_club_short_name', v_f.home_club_short_name,
    'away_club_short_name', v_f.away_club_short_name,
    'home_goals', v_f.home_goals,
    'away_goals', v_f.away_goals,
    'is_forfeit', coalesce(v_f.is_forfeit, false),
    'schedule_status', (
      SELECT sch.status FROM public.competition_fixture_schedule sch
      WHERE sch.fixture_id = v_f.id
    ),
    'agreed_kickoff_at', (
      SELECT sch.agreed_kickoff_at FROM public.competition_fixture_schedule sch
      WHERE sch.fixture_id = v_f.id
    ),
    'submissions', (
      SELECT count(*)::int FROM public.competition_result_submissions s
      WHERE s.fixture_id = v_f.id
    ),
    'stats', (
      SELECT count(*)::int FROM public.competition_match_player_stats m
      WHERE m.fixture_id = v_f.id
    ),
    'videos', (
      SELECT count(*)::int FROM public.fixture_match_videos v
      WHERE v.fixture_id = v_f.id
    ),
    'pending_videos', (
      SELECT count(*)::int FROM public.fixture_match_video_pending pv
      WHERE pv.fixture_id = v_f.id
    ),
    'ledger_rows', (
      SELECT count(*)::int FROM public.competition_finance_ledger l
      WHERE l.fixture_id = v_f.id
    ),
    'checkins', (
      SELECT count(*)::int FROM public.competition_fixture_checkin c
      WHERE c.fixture_id = v_f.id
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_fixture_reset_for_replay(
  p_fixture_id bigint,
  p_reason text DEFAULT NULL,
  p_confirm_phrase text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fid bigint := p_fixture_id;
  v_f public.competition_fixtures%ROWTYPE;
  v_home text;
  v_away text;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_note text;
  v_video jsonb;
  v_ledger record;
  v_n int := 0;
  v_stats int := 0;
  v_subs int := 0;
  v_ledger_n int := 0;
  v_susp int := 0;
  v_inj int := 0;
  v_fit_home jsonb;
  v_fit_away jsonb;
  v_before jsonb;
  v_after jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF coalesce(btrim(p_confirm_phrase), '') <> 'RESET FIXTURE REPLAY' THEN
    RAISE EXCEPTION 'Confirmation phrase required — type exactly: RESET FIXTURE REPLAY';
  END IF;

  IF v_fid IS NULL THEN
    RAISE EXCEPTION 'fixture_id required';
  END IF;

  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = v_fid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture % not found', v_fid;
  END IF;

  v_home := upper(btrim(v_f.home_club_short_name));
  v_away := upper(btrim(v_f.away_club_short_name));
  v_reason := coalesce(v_reason, 'Admin reset for replay');
  v_note := format(
    'Admin fixture reset for replay (%s) %s',
    v_reason,
    to_char(now() AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI')
  );

  v_before := public.admin_fixture_reset_preview(v_fid);

  -- 1) Videos
  IF to_regprocedure('public.match_video_admin_clear(bigint, text)') IS NOT NULL THEN
    v_video := public.match_video_admin_clear(v_fid, NULL);
  END IF;
  DELETE FROM public.fixture_match_video_pending WHERE fixture_id = v_fid;
  DELETE FROM public.fixture_match_videos WHERE fixture_id = v_fid;

  IF to_regclass('public.match_video_breach_reports') IS NOT NULL THEN
    UPDATE public.match_video_breach_reports
    SET review_note = trim(both E'\n' from coalesce(review_note, '') || E'\n' || v_note)
    WHERE fixture_id = v_fid;
  END IF;

  -- 2) Finance reverse
  -- Video credits were already balance-reversed by match_video_admin_clear
  -- (which inserts offsetting gate_match_video rows). Drop ALL video ledger
  -- rows for this fixture without a second balance pass.
  DELETE FROM public.competition_finance_ledger
  WHERE fixture_id = v_fid
    AND entry_type = 'gate_match_video';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_ledger_n := v_ledger_n + v_n;

  FOR v_ledger IN
    SELECT id, club_short_name, amount
    FROM public.competition_finance_ledger
    WHERE fixture_id = v_fid
  LOOP
    IF to_regprocedure('public.competition_credit_club_balance(text, numeric)') IS NOT NULL THEN
      PERFORM public.competition_credit_club_balance(
        v_ledger.club_short_name,
        -coalesce(v_ledger.amount, 0)
      );
    END IF;
    DELETE FROM public.competition_finance_ledger WHERE id = v_ledger.id;
    v_ledger_n := v_ledger_n + 1;
  END LOOP;

  -- 3) Stats + submissions
  IF to_regclass('public.competition_match_player_stats') IS NOT NULL THEN
    DELETE FROM public.competition_match_player_stats WHERE fixture_id = v_fid;
    GET DIAGNOSTICS v_stats = ROW_COUNT;
  END IF;

  IF to_regclass('public.competition_result_submissions') IS NOT NULL THEN
    DELETE FROM public.competition_result_submissions WHERE fixture_id = v_fid;
    GET DIAGNOSTICS v_subs = ROW_COUNT;
  END IF;

  -- 4) Discipline
  IF to_regclass('public.competition_player_suspension_matches') IS NOT NULL THEN
    DELETE FROM public.competition_player_suspension_matches
    WHERE fixture_id = v_fid;
  END IF;
  IF to_regclass('public.competition_player_suspensions') IS NOT NULL THEN
    DELETE FROM public.competition_player_suspensions
    WHERE source_fixture_id = v_fid;
    GET DIAGNOSTICS v_susp = ROW_COUNT;
  END IF;

  IF to_regclass('public.competition_player_injury_fixtures') IS NOT NULL THEN
    DELETE FROM public.competition_player_injury_fixtures
    WHERE fixture_id = v_fid;
  END IF;
  IF to_regclass('public.competition_player_injuries') IS NOT NULL THEN
    UPDATE public.competition_player_injuries i
    SET status = 'cancelled'
    WHERE i.source_fixture_id = v_fid
      AND i.status = 'active';
    GET DIAGNOSTICS v_inj = ROW_COUNT;
  END IF;

  IF to_regprocedure('public.competition_resync_pending_suspensions(bigint, text)') IS NOT NULL THEN
    PERFORM public.competition_resync_pending_suspensions(v_f.season_id, v_home);
    PERFORM public.competition_resync_pending_suspensions(v_f.season_id, v_away);
  END IF;

  -- 5) Fitness tick
  IF to_regclass('public.competition_fixture_match_fitness_tick') IS NOT NULL THEN
    DELETE FROM public.competition_fixture_match_fitness_tick
    WHERE fixture_id = v_fid;
  END IF;

  -- 6) Fixture → scheduled / unplayed
  UPDATE public.competition_fixtures
  SET
    status = 'scheduled',
    home_goals = NULL,
    away_goals = NULL,
    is_forfeit = false,
    forfeit_loser_club = NULL,
    is_void = false
  WHERE id = v_fid;

  -- 7) Schedule → unscheduled
  DELETE FROM public.competition_fixture_schedule_proposal WHERE fixture_id = v_fid;
  DELETE FROM public.competition_fixture_checkin WHERE fixture_id = v_fid;

  UPDATE public.competition_fixture_schedule
  SET
    status = 'unscheduled',
    agreed_kickoff_at = NULL,
    pending_proposal_id = NULL,
    response_due_at = NULL,
    response_required_club_short_name = NULL,
    response_miss_count = 0,
    no_show_club_short_name = NULL,
    no_show_kickoff_at = NULL,
    home_proposal_count = 0,
    away_proposal_count = 0,
    discord_hint_shown = false,
    mutual_override_used = false,
    updated_at = now()
  WHERE fixture_id = v_fid;

  IF NOT FOUND THEN
    INSERT INTO public.competition_fixture_schedule (fixture_id, status)
    VALUES (v_fid, 'unscheduled')
    ON CONFLICT (fixture_id) DO UPDATE
    SET status = 'unscheduled',
        agreed_kickoff_at = NULL,
        pending_proposal_id = NULL,
        home_proposal_count = 0,
        away_proposal_count = 0,
        updated_at = now();
  END IF;

  -- 8) Inbox
  UPDATE public.competition_inbox
  SET archived_at = coalesce(archived_at, now()),
      read_at = coalesce(read_at, now())
  WHERE fixture_id = v_fid
    AND archived_at IS NULL
    AND message_type IN (
      'match_time_proposed',
      'match_time_countered',
      'match_time_proposal_sent',
      'match_time_counter_sent',
      'match_time_accepted',
      'match_rescheduled',
      'match_emergency_drop',
      'match_checkin_open',
      'match_mutual_override_requested',
      'match_mutual_override_applied',
      'match_no_show',
      'result_to_confirm',
      'result_submitted',
      'result_confirmed'
    );
  GET DIAGNOSTICS v_n = ROW_COUNT;

  -- 9) Fitness rebuild
  IF to_regprocedure('public.admin_match_fitness_rebuild_streaks(bigint, text)') IS NOT NULL THEN
    v_fit_home := public.admin_match_fitness_rebuild_streaks(v_f.season_id, v_home);
    v_fit_away := public.admin_match_fitness_rebuild_streaks(v_f.season_id, v_away);
  END IF;

  v_after := public.admin_fixture_reset_preview(v_fid);

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', v_fid,
    'reason', v_reason,
    'home', v_home,
    'away', v_away,
    'cleared', jsonb_build_object(
      'stats', v_stats,
      'submissions', v_subs,
      'ledger_rows', v_ledger_n,
      'suspensions', v_susp,
      'injuries_cancelled', v_inj,
      'inbox_archived', v_n,
      'video_clear', v_video
    ),
    'fitness_rebuild', jsonb_build_object(
      'home', v_fit_home,
      'away', v_fit_away
    ),
    'before', v_before,
    'after', v_after
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_fixture_reset_preview(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_fixture_reset_for_replay(bigint, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_fixture_reset_preview(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_fixture_reset_for_replay(bigint, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
