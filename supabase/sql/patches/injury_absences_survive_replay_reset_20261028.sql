-- =============================================================================
-- Injury absences must survive fixture replay reset (2026-10-28)
-- =============================================================================
-- Bug: admin_fixture_reset_for_replay deleted competition_player_injury_fixtures
-- for the fixture and never rebound them (suspensions were resynced). Players
-- who were injured for the original match then showed available on the replay.
--
-- Fix:
--   1) Preserve absences not caused BY this fixture; undo serve consumption;
--      re-stick to the same fixture_id after it returns to scheduled.
--   2) competition_resync_pending_injuries — reassign active injuries (parity
--      with suspensions).
--   3) admin_repair_replay_fixture_injuries — catch-up for fixtures already reset.
--   4) Unavailable read resyncs injuries for unplayed fixtures.
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Reassign active injuries for a club (like suspension resync)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_resync_pending_injuries(
  p_season_id bigint,
  p_club text
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(coalesce(p_club, '')));
  v_n int := 0;
  r record;
BEGIN
  IF v_club = '' OR p_season_id IS NULL THEN
    RETURN 0;
  END IF;

  IF to_regprocedure('public.competition_injury_assign_fixtures(bigint)') IS NULL THEN
    RETURN 0;
  END IF;

  FOR r IN
    SELECT i.id
    FROM public.competition_player_injuries i
    WHERE upper(btrim(i.club_short_name)) = v_club
      AND i.status = 'active'
      AND (
        coalesce(i.matches_out_remaining, 0) > 0
        OR coalesce(i.recovery_remaining, 0) > 0
      )
      AND (
        i.season_id = p_season_id
        OR i.incurred_season_id = p_season_id
        OR (i.season_id IS NULL AND i.incurred_season_id IS NULL)
      )
  LOOP
    PERFORM public.competition_injury_assign_fixtures(r.id);
    v_n := v_n + 1;
  END LOOP;

  RETURN v_n;
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_resync_pending_injuries(bigint, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.competition_resync_pending_injuries(bigint, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Undo a served absence on an injury (restore remaining + reactivate)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_injury_undo_absence_serve(
  p_injury_id bigint,
  p_phase text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_phase text := lower(btrim(coalesce(p_phase, 'out')));
BEGIN
  IF v_phase = 'recovery' THEN
    UPDATE public.competition_player_injuries i
    SET recovery_remaining = coalesce(i.recovery_remaining, 0) + 1,
        status = 'active',
        recovered_at = NULL
    WHERE i.id = p_injury_id;
  ELSE
    UPDATE public.competition_player_injuries i
    SET matches_out_remaining = coalesce(i.matches_out_remaining, 0) + 1,
        status = 'active',
        recovered_at = NULL
    WHERE i.id = p_injury_id;
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_injury_undo_absence_serve(bigint, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.competition_injury_undo_absence_serve(bigint, text)
  TO service_role;

-- ---------------------------------------------------------------------------
-- Repair one already-reset replay fixture (admin)
-- Restores sticky absences for active injuries that still have matches left
-- (or that already consumed a serve vs original matches_out).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_repair_replay_fixture_injuries(
  p_fixture_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_f public.competition_fixtures%ROWTYPE;
  v_home text;
  v_away text;
  v_bumped int := 0;
  v_stuck int := 0;
  v_assigned int := 0;
  r record;
  v_need int;
  v_links int;
  v_phase text;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'fixture_not_found');
  END IF;

  IF lower(coalesce(v_f.status, '')) NOT IN ('scheduled') THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'fixture_not_scheduled',
      'status', v_f.status
    );
  END IF;

  v_home := upper(btrim(v_f.home_club_short_name));
  v_away := upper(btrim(v_f.away_club_short_name));

  FOR r IN
    SELECT i.*
    FROM public.competition_player_injuries i
    WHERE upper(btrim(i.club_short_name)) IN (v_home, v_away)
      AND i.status IN ('active', 'recovered')
      AND i.source_fixture_id IS DISTINCT FROM p_fixture_id
      AND (
        coalesce(i.matches_out_remaining, 0) > 0
        OR coalesce(i.recovery_remaining, 0) > 0
        OR coalesce(i.matches_out_remaining, 0) < coalesce(i.matches_out, 0)
        OR coalesce(i.recovery_remaining, 0) < coalesce(i.recovery_matches, 0)
      )
  LOOP
    -- Skip injuries incurred on a later matchday than this fixture
    IF r.source_fixture_id IS NOT NULL THEN
      IF EXISTS (
        SELECT 1
        FROM public.competition_fixtures sf
        WHERE sf.id = r.source_fixture_id
          AND coalesce(sf.matchday, 0) > coalesce(v_f.matchday, 0)
      ) THEN
        CONTINUE;
      END IF;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.competition_player_injury_fixtures iff
      WHERE iff.injury_id = r.id
        AND iff.fixture_id = p_fixture_id
        AND iff.served = false
    ) THEN
      CONTINUE;
    END IF;

    v_need := coalesce(r.matches_out_remaining, 0) + coalesce(r.recovery_remaining, 0);
    SELECT count(*)::int INTO v_links
    FROM public.competition_player_injury_fixtures iff
    WHERE iff.injury_id = r.id
      AND iff.served = false;

    -- Restore one consumed serve when the replay fixture lost its link
    IF v_need <= v_links
       OR coalesce(r.matches_out_remaining, 0) < coalesce(r.matches_out, 0)
       OR coalesce(r.recovery_remaining, 0) < coalesce(r.recovery_matches, 0)
       OR r.status = 'recovered'
    THEN
      IF coalesce(r.matches_out_remaining, 0) < coalesce(r.matches_out, 0)
         OR (coalesce(r.matches_out, 0) > 0 AND coalesce(r.recovery_remaining, 0) >= coalesce(r.recovery_matches, 0))
      THEN
        v_phase := 'out';
        PERFORM public.competition_injury_undo_absence_serve(r.id, 'out');
      ELSE
        v_phase := 'recovery';
        PERFORM public.competition_injury_undo_absence_serve(r.id, 'recovery');
      END IF;
      v_bumped := v_bumped + 1;
    ELSE
      v_phase := CASE
        WHEN coalesce(r.matches_out_remaining, 0) > 0 THEN 'out'
        ELSE 'recovery'
      END;
    END IF;

    INSERT INTO public.competition_player_injury_fixtures (
      injury_id, fixture_id, phase, served
    )
    VALUES (r.id, p_fixture_id, v_phase, false)
    ON CONFLICT (injury_id, fixture_id) DO UPDATE
      SET phase = EXCLUDED.phase,
          served = false;
    v_stuck := v_stuck + 1;

    IF to_regprocedure('public.competition_injury_assign_fixtures(bigint)') IS NOT NULL THEN
      PERFORM public.competition_injury_assign_fixtures(r.id);
      v_assigned := v_assigned + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'home', v_home,
    'away', v_away,
    'remaining_bumped', v_bumped,
    'links_stuck', v_stuck,
    'injuries_reassigned', v_assigned
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_repair_replay_fixture_injuries(bigint)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_repair_replay_fixture_injuries(bigint)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Patch admin_fixture_reset_for_replay — preserve injury absences
-- ---------------------------------------------------------------------------
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
  v_inj_restored int := 0;
  v_fit_home jsonb;
  v_fit_away jsonb;
  v_before jsonb;
  v_after jsonb;
  v_preserve jsonb := '[]'::jsonb;
  v_row jsonb;
  v_phase text;
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

  -- 4) Discipline — capture injury absences to restore after wipe
  IF to_regclass('public.competition_player_injury_fixtures') IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'injury_id', iff.injury_id,
             'phase', iff.phase,
             'served', iff.served
           )), '[]'::jsonb)
    INTO v_preserve
    FROM public.competition_player_injury_fixtures iff
    JOIN public.competition_player_injuries i ON i.id = iff.injury_id
    WHERE iff.fixture_id = v_fid
      AND i.source_fixture_id IS DISTINCT FROM v_fid;
  END IF;

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

  -- 7b) Restore injury absences onto the replay fixture (parity with suspensions)
  IF to_regclass('public.competition_player_injury_fixtures') IS NOT NULL THEN
    FOR v_row IN
      SELECT value AS j FROM jsonb_array_elements(coalesce(v_preserve, '[]'::jsonb))
    LOOP
      v_phase := lower(coalesce(v_row.j->>'phase', 'out'));

      IF coalesce((v_row.j->>'served')::boolean, false) THEN
        PERFORM public.competition_injury_undo_absence_serve(
          (v_row.j->>'injury_id')::bigint,
          v_phase
        );
      END IF;

      -- Only stick if injury is still active with remaining after undo/cancel filter
      IF EXISTS (
        SELECT 1
        FROM public.competition_player_injuries i
        WHERE i.id = (v_row.j->>'injury_id')::bigint
          AND i.status = 'active'
          AND (
            coalesce(i.matches_out_remaining, 0) > 0
            OR coalesce(i.recovery_remaining, 0) > 0
          )
      ) THEN
        INSERT INTO public.competition_player_injury_fixtures (
          injury_id, fixture_id, phase, served
        )
        VALUES (
          (v_row.j->>'injury_id')::bigint,
          v_fid,
          v_phase,
          false
        )
        ON CONFLICT (injury_id, fixture_id) DO UPDATE
          SET phase = EXCLUDED.phase,
              served = false;
        v_inj_restored := v_inj_restored + 1;
      END IF;
    END LOOP;
  END IF;

  IF to_regprocedure('public.competition_resync_pending_injuries(bigint, text)') IS NOT NULL THEN
    PERFORM public.competition_resync_pending_injuries(v_f.season_id, v_home);
    PERFORM public.competition_resync_pending_injuries(v_f.season_id, v_away);
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
      'injury_absences_restored', v_inj_restored,
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

REVOKE ALL ON FUNCTION public.admin_fixture_reset_for_replay(bigint, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_fixture_reset_for_replay(bigint, text, text)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- Unavailable read: also resync injuries for unplayed fixtures
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_fixture_unavailable_players(
  p_fixture_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures%rowtype;
  v_home jsonb;
  v_away jsonb;
  v_played boolean := false;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  v_played := lower(coalesce(v_fixture.status, '')) IN ('played', 'completed', 'forfeit');

  IF NOT v_played
     AND to_regprocedure('public.competition_resync_pending_suspensions(bigint, text)') IS NOT NULL THEN
    PERFORM public.competition_resync_pending_suspensions(
      v_fixture.season_id, v_fixture.home_club_short_name
    );
    PERFORM public.competition_resync_pending_suspensions(
      v_fixture.season_id, v_fixture.away_club_short_name
    );
  END IF;

  IF NOT v_played
     AND to_regprocedure('public.competition_resync_pending_injuries(bigint, text)') IS NOT NULL THEN
    PERFORM public.competition_resync_pending_injuries(
      v_fixture.season_id, v_fixture.home_club_short_name
    );
    PERFORM public.competition_resync_pending_injuries(
      v_fixture.season_id, v_fixture.away_club_short_name
    );
  END IF;

  WITH suspended AS (
    SELECT
      s.club_short_name,
      s.player_id,
      p."Name" AS player_name,
      p."Position" AS position,
      'suspended'::text AS reason,
      CASE
        WHEN s.reason = 'red_card' THEN 'Suspended — red card (2-match ban)'
        WHEN s.reason = 'yellow_accumulation' THEN
          format(
            'Suspended — %s yellows (2-match ban)',
            coalesce(s.yellow_count_at_issue, 8)
          )
        ELSE 'Suspended'
      END AS detail,
      s.id AS source_id
    FROM public.competition_player_suspension_matches sm
    JOIN public.competition_player_suspensions s ON s.id = sm.suspension_id
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = s.player_id
    WHERE sm.fixture_id = p_fixture_id
      AND (s.status = 'active' OR v_played)
  ),
  injured AS (
    SELECT
      i.club_short_name,
      i.player_id,
      p."Name" AS player_name,
      p."Position" AS position,
      CASE
        WHEN iff.phase = 'recovery' THEN 'recovery'
        ELSE 'injured'
      END AS reason,
      CASE
        WHEN iff.phase = 'recovery' THEN
          format('Gaining match fitness — %s', coalesce(i.label, 'Injury'))
        ELSE
          format('Injured — %s', coalesce(i.label, 'Injured'))
      END AS detail,
      i.id AS source_id
    FROM public.competition_player_injury_fixtures iff
    JOIN public.competition_player_injuries i ON i.id = iff.injury_id
    LEFT JOIN public."Players" p ON p."Konami_ID"::text = i.player_id
    WHERE iff.fixture_id = p_fixture_id
      AND (i.status = 'active' OR v_played)
  ),
  combined AS (
    SELECT * FROM suspended
    UNION ALL
    SELECT * FROM injured
  )
  SELECT
    coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'player_id', c.player_id,
          'player_name', coalesce(c.player_name, c.player_id),
          'position', c.position,
          'reason', c.reason,
          'detail', c.detail,
          'source_id', c.source_id
        )
        ORDER BY c.reason, c.player_name
      )
      FROM combined c
      WHERE upper(btrim(c.club_short_name)) = upper(btrim(v_fixture.home_club_short_name))
    ), '[]'::jsonb),
    coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'player_id', c.player_id,
          'player_name', coalesce(c.player_name, c.player_id),
          'position', c.position,
          'reason', c.reason,
          'detail', c.detail,
          'source_id', c.source_id
        )
        ORDER BY c.reason, c.player_name
      )
      FROM combined c
      WHERE upper(btrim(c.club_short_name)) = upper(btrim(v_fixture.away_club_short_name))
    ), '[]'::jsonb)
  INTO v_home, v_away;

  RETURN jsonb_build_object(
    'fixture_id', p_fixture_id,
    'home_club_short_name', v_fixture.home_club_short_name,
    'away_club_short_name', v_fixture.away_club_short_name,
    'home', coalesce(v_home, '[]'::jsonb),
    'away', coalesce(v_away, '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_fixture_unavailable_players(bigint)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- DIAGNOSE: scheduled fixtures where club has active injuries but no link
-- ---------------------------------------------------------------------------
SELECT
  f.id AS fixture_id,
  f.matchday,
  f.home_club_short_name AS home,
  f.away_club_short_name AS away,
  i.club_short_name,
  i.player_id,
  p."Name" AS player_name,
  i.label,
  i.matches_out_remaining,
  i.recovery_remaining,
  i.status
FROM public.competition_fixtures f
JOIN public.competition_player_injuries i
  ON upper(btrim(i.club_short_name)) IN (
       upper(btrim(f.home_club_short_name)),
       upper(btrim(f.away_club_short_name))
     )
  AND i.status = 'active'
  AND (
    coalesce(i.matches_out_remaining, 0) > 0
    OR coalesce(i.recovery_remaining, 0) > 0
  )
  AND i.source_fixture_id IS DISTINCT FROM f.id
LEFT JOIN public."Players" p ON p."Konami_ID"::text = i.player_id
WHERE f.status = 'scheduled'
  AND NOT EXISTS (
    SELECT 1
    FROM public.competition_player_injury_fixtures iff
    WHERE iff.injury_id = i.id
      AND iff.fixture_id = f.id
      AND iff.served = false
  )
ORDER BY f.matchday, f.id, i.club_short_name;

-- Repair one fixture (edit id):
-- SELECT public.admin_repair_replay_fixture_injuries(9027);

-- Or repair every diagnosed fixture:
-- SELECT f.id, public.admin_repair_replay_fixture_injuries(f.id)
-- FROM (
--   SELECT DISTINCT f.id
--   FROM public.competition_fixtures f
--   JOIN public.competition_player_injuries i
--     ON upper(btrim(i.club_short_name)) IN (
--          upper(btrim(f.home_club_short_name)),
--          upper(btrim(f.away_club_short_name))
--        )
--    AND i.status = 'active'
--    AND (coalesce(i.matches_out_remaining,0) > 0 OR coalesce(i.recovery_remaining,0) > 0)
--    AND i.source_fixture_id IS DISTINCT FROM f.id
--   WHERE f.status = 'scheduled'
--     AND NOT EXISTS (
--       SELECT 1 FROM public.competition_player_injury_fixtures iff
--       WHERE iff.injury_id = i.id AND iff.fixture_id = f.id AND iff.served = false
--     )
-- ) f;
