-- =============================================================================
-- No check-in or Play now before the fixture's GPSL month opens
--
-- Ajax v Arsenal: a November fixture was agreed for 12 Nov 19:00 UK and both
-- clubs could check in and play while GPSL November was still locked.
-- play_month_open is only "not yet locked", so a future month already counts
-- as open. Check-in and Play now looked only at the kick-off clock.
--
-- Play is allowed when that fixture month has unlocked and not yet locked,
-- or the fixture is catch-up, or it is holiday-early.
-- Arranging a kick-off in advance is unchanged.
--
-- Run once in the Supabase SQL editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_fixture_may_play(p_fixture_id bigint)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_unlock timestamptz;
  v_lock timestamptz;
BEGIN
  IF to_regprocedure('public.match_schedule_fixture_is_catch_up(bigint)') IS NOT NULL
     AND public.match_schedule_fixture_is_catch_up(p_fixture_id) THEN
    RETURN true;
  END IF;

  IF to_regprocedure('public.match_schedule_fixture_is_holiday_early(bigint)') IS NOT NULL
     AND public.match_schedule_fixture_is_holiday_early(p_fixture_id) THEN
    RETURN true;
  END IF;

  SELECT cal.unlock_at, cal.lock_at
  INTO v_unlock, v_lock
  FROM public.competition_fixtures f
  JOIN public.competition_season_calendar cal
    ON cal.season_id = f.season_id
   AND cal.gpsl_month = f.gpsl_month
  WHERE f.id = p_fixture_id;

  IF NOT FOUND OR v_unlock IS NULL THEN
    RETURN false;
  END IF;

  RETURN now() >= v_unlock
     AND (v_lock IS NULL OR now() < v_lock);
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_fixture_may_play(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.match_schedule_fixture_may_play(bigint)
  TO authenticated, service_role;

-- Inject the gate into the live check-in, Play now, and the flags the pages read.
DO $gate$
DECLARE
  v_oid oid;
  v_def text;
  v_new text;
  v_guard text := E'  IF NOT public.match_schedule_fixture_may_play(p_fixture_id) THEN\n'
    || E'    RAISE EXCEPTION ''This GPSL month is not open yet'';\n'
    || E'  END IF;\n';
BEGIN
  -- Check-in (also covers a Play now check-in, which uses the same function)
  v_oid := to_regprocedure('public.fixture_check_in(bigint)');
  IF v_oid IS NULL THEN
    RAISE WARNING 'fixture_check_in missing';
  ELSE
    v_def := pg_get_functiondef(v_oid);
    IF position('match_schedule_fixture_may_play' IN v_def) = 0 THEN
      v_new := replace(
        v_def,
        E'  IF v_kickoff IS NULL THEN\n    RAISE EXCEPTION ''Kick-off time is not agreed yet'';\n  END IF;\n',
        E'  IF v_kickoff IS NULL THEN\n    RAISE EXCEPTION ''Kick-off time is not agreed yet'';\n  END IF;\n'
          || v_guard
      );
      IF v_new = v_def THEN
        RAISE WARNING 'fixture_check_in: kick-off guard not found — check-in was not patched';
      ELSE
        EXECUTE v_new;
      END IF;
    END IF;
  END IF;

  -- Play now press
  v_oid := to_regprocedure('public.fixture_play_now_press(bigint)');
  IF v_oid IS NULL THEN
    RAISE WARNING 'fixture_play_now_press missing';
  ELSE
    v_def := pg_get_functiondef(v_oid);
    IF position('match_schedule_fixture_may_play' IN v_def) = 0 THEN
      v_new := replace(
        v_def,
        E'  IF v_kickoff IS NULL THEN\n    RAISE EXCEPTION ''Agree a kick-off before using Play now'';\n  END IF;\n',
        E'  IF v_kickoff IS NULL THEN\n    RAISE EXCEPTION ''Agree a kick-off before using Play now'';\n  END IF;\n'
          || v_guard
      );
      IF v_new = v_def THEN
        RAISE WARNING 'fixture_play_now_press: kick-off guard not found — Play now was not patched';
      ELSE
        EXECUTE v_new;
      END IF;
    END IF;
  END IF;

  -- Play now button (can_press) and its check-in
  v_oid := to_regprocedure('public.match_schedule_play_now_session_json(bigint)');
  IF v_oid IS NOT NULL THEN
    v_def := pg_get_functiondef(v_oid);
    IF position('match_schedule_fixture_may_play' IN v_def) = 0 THEN
      v_new := replace(
        v_def,
        'AND v_kickoff > now()',
        'AND v_kickoff > now() AND public.match_schedule_fixture_may_play(p_fixture_id)'
      );
      v_new := replace(
        v_new,
        E'  v_can_check_in :=\n    v_sess.status IN (''open'', ''both_ready'')',
        E'  v_can_check_in :=\n    public.match_schedule_fixture_may_play(p_fixture_id)\n    AND v_sess.status IN (''open'', ''both_ready'')'
      );
      IF v_new = v_def THEN
        RAISE WARNING 'play_now_session_json: could not add the month gate';
      ELSE
        EXECUTE v_new;
      END IF;
    END IF;
  END IF;

  -- Schedule page check-in / play flags
  v_oid := to_regprocedure('public.match_schedule_fixture_context(bigint)');
  IF v_oid IS NOT NULL THEN
    v_def := pg_get_functiondef(v_oid);
    IF position('match_schedule_fixture_may_play' IN v_def) = 0 THEN
      v_new := replace(
        v_def,
        'AND NOT v_my_in AND v_has_mgr)',
        'AND NOT v_my_in AND v_has_mgr AND public.match_schedule_fixture_may_play(p_fixture_id))'
      );
      v_new := replace(
        v_new,
        'AND v_home_in AND v_away_in AND now() >= v_kickoff AND now() < v_kickoff + (public.match_schedule_block_minutes() || '' minutes'')::interval)',
        'AND v_home_in AND v_away_in AND now() >= v_kickoff AND now() < v_kickoff + (public.match_schedule_block_minutes() || '' minutes'')::interval AND public.match_schedule_fixture_may_play(p_fixture_id))'
      );
      IF v_new = v_def THEN
        RAISE WARNING 'match_schedule_fixture_context: check-in flag not patched';
      ELSE
        EXECUTE v_new;
      END IF;
    END IF;
  END IF;

  -- Dashboard match card
  v_oid := to_regprocedure('public.dashboard_my_matchday_synopsis()');
  IF v_oid IS NOT NULL THEN
    v_def := pg_get_functiondef(v_oid);
    IF position('match_schedule_fixture_may_play' IN v_def) = 0 THEN
      v_new := replace(
        v_def,
        E'    WHERE f.status = ''scheduled''\n',
        E'    WHERE f.status = ''scheduled''\n'
          || E'      AND public.match_schedule_fixture_may_play(f.id)\n'
      );
      IF v_new = v_def THEN
        RAISE WARNING 'dashboard_my_matchday_synopsis: month gate not patched';
      ELSE
        EXECUTE v_new;
      END IF;
    END IF;
  END IF;
END;
$gate$;

NOTIFY pgrst, 'reload schema';
