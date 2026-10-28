-- =============================================================================
-- Admin: time competition_confirm_result on a pending submission, then optional
-- reset via admin_fixture_reset_for_replay (same wipe as Admin → Reset fixture).
--
-- Also hardens confirm:
--   • ALTER FUNCTION statement_timeout = 180s (more reliable than set_config alone)
--   • Do NOT soft-run clinch/bookies at end of confirm (those can still blow the
--     budget / gateway even when wrapped in EXCEPTION)
--   • Keep skip GUCs during the played UPDATE
--
-- Example (COR vs JUB SuperLeague MD3):
--   select public.admin_test_confirm_pending_result(
--     'COR', 'JUB', 3, 'superleague', true
--   );
--
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Harden triggers (idempotent with prior patch)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_competition_fixtures_bookies_reprice()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF current_setting('gpsl.skip_bookies_reprice', true) = 'on' THEN
    RETURN NEW;
  END IF;

  IF NEW.status = 'played'
     AND coalesce(OLD.status, '') IS DISTINCT FROM 'played'
     AND coalesce(NEW.competition_type, 'league') IN ('league', 'cup')
     AND EXISTS (
       SELECT 1 FROM public.bookies_markets m
       WHERE m.season_id = NEW.season_id
         AND m.status IN ('open', 'closed')
     ) THEN
    BEGIN
      PERFORM public.admin_bookies_recompute_all_odds(NEW.season_id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'bookies reprice after fixture % failed: %', NEW.id, SQLERRM;
    END;
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_fixture_played()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.status IS DISTINCT FROM 'played' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM 'played' THEN
    RETURN NEW;
  END IF;
  IF NEW.home_goals IS NULL OR NEW.away_goals IS NULL THEN
    RETURN NEW;
  END IF;

  IF current_setting('gpsl.skip_clinch_scan', true) = 'on' THEN
    RETURN NEW;
  END IF;

  IF coalesce(NEW.competition_type, 'league') = 'league'
     AND nullif(btrim(coalesce(NEW.cup_code, '')), '') IS NULL THEN
    BEGIN
      PERFORM public.competition_process_league_clinches(NEW.season_id);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Harden competition_confirm_result — no end-of-call clinch/bookies
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_confirm_result(
  p_submission_id bigint,
  p_confirmer_player_stats jsonb DEFAULT '[]'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '180s'
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_sub public.competition_result_submissions;
  v_fixture public.competition_fixtures;
  v_opponent text;
  v_home_name text;
  v_away_name text;
  v_label text;
  v_home_total smallint;
  v_away_total smallint;
  v_body text;
  v_pen_winner_name text;
  v_confirmer_expected int;
BEGIN
  PERFORM set_config('statement_timeout', '180s', true);
  PERFORM set_config('gpsl.skip_clinch_scan', 'on', true);
  PERFORM set_config('gpsl.skip_bookies_reprice', 'on', true);

  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF p_confirmer_player_stats IS NULL OR jsonb_typeof(p_confirmer_player_stats) <> 'array' THEN
    RAISE EXCEPTION 'player_stats must be a JSON array';
  END IF;

  IF jsonb_array_length(p_confirmer_player_stats) = 0 THEN
    RAISE EXCEPTION 'Enter your squad match stats (11 starters) before confirming';
  END IF;

  SELECT * INTO v_sub
  FROM public.competition_result_submissions
  WHERE id = p_submission_id AND status = 'pending';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pending submission not found';
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = v_sub.fixture_id;

  v_opponent := public.competition_fixture_opponent(v_sub.fixture_id, v_club);
  IF v_opponent <> v_sub.submitted_by_club THEN
    RAISE EXCEPTION 'Only the opponent can confirm this result';
  END IF;

  v_confirmer_expected := public.competition_expected_goals_for_club(v_fixture, v_sub, v_club);

  IF v_fixture.competition_type = 'cup' THEN
    SELECT t.home_total, t.away_total
    INTO v_home_total, v_away_total
    FROM public.competition_cup_open_play_totals(
      v_sub.home_goals, v_sub.away_goals, v_sub.et_home_goals, v_sub.et_away_goals
    ) t;

    IF public.competition_cup_winner_from_submission(
      v_sub.home_goals, v_sub.away_goals, v_sub.et_home_goals, v_sub.et_away_goals,
      v_sub.pen_winner_club_short_name,
      v_fixture.home_club_short_name, v_fixture.away_club_short_name
    ) IS NULL THEN
      RAISE EXCEPTION 'Invalid cup submission — extra time or penalties required';
    END IF;

    UPDATE public.competition_fixtures
    SET home_goals = v_home_total,
        away_goals = v_away_total,
        cup_pen_winner_club_short_name = v_sub.pen_winner_club_short_name,
        status = 'played'
    WHERE id = v_sub.fixture_id;
  ELSE
    v_home_total := v_sub.home_goals;
    v_away_total := v_sub.away_goals;

    UPDATE public.competition_fixtures
    SET home_goals = v_sub.home_goals,
        away_goals = v_sub.away_goals,
        cup_pen_winner_club_short_name = NULL,
        status = 'played'
    WHERE id = v_sub.fixture_id;
  END IF;

  PERFORM public.competition_apply_submission_player_stats(p_submission_id);

  PERFORM public.competition_apply_club_player_stats(
    v_fixture.id,
    v_fixture.season_id,
    v_club,
    p_confirmer_player_stats,
    v_confirmer_expected
  );

  PERFORM public.competition_settle_fixture_gates(v_sub.fixture_id);

  IF to_regprocedure('public.competition_tv_settle_fixture(bigint)') IS NOT NULL THEN
    PERFORM public.competition_tv_settle_fixture(v_sub.fixture_id);
  END IF;

  IF to_regprocedure('public.competition_try_award_challenges(bigint,text,boolean)') IS NOT NULL THEN
    BEGIN
      PERFORM public.competition_try_award_challenges(
        v_fixture.season_id, v_fixture.home_club_short_name, false
      );
      PERFORM public.competition_try_award_challenges(
        v_fixture.season_id, v_fixture.away_club_short_name, false
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'challenges after confirm fixture % failed: %', v_fixture.id, SQLERRM;
    END;
  ELSIF to_regprocedure('public.competition_try_award_challenges(bigint,text)') IS NOT NULL THEN
    BEGIN
      PERFORM public.competition_try_award_challenges(
        v_fixture.season_id, v_fixture.home_club_short_name
      );
      PERFORM public.competition_try_award_challenges(
        v_fixture.season_id, v_fixture.away_club_short_name
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'challenges after confirm fixture % failed: %', v_fixture.id, SQLERRM;
    END;
  END IF;

  IF v_fixture.competition_type = 'cup' THEN
    PERFORM public.competition_cup_on_fixture_played(v_sub.fixture_id);
  ELSIF v_fixture.competition_type = 'league'
     AND to_regprocedure(
           'public.competition_try_pay_league_division_prizes(bigint,text)'
         ) IS NOT NULL THEN
    BEGIN
      PERFORM public.competition_try_pay_league_division_prizes(
        v_fixture.season_id, v_fixture.division
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'league prizes after confirm fixture % failed: %', v_fixture.id, SQLERRM;
    END;
  END IF;

  UPDATE public.competition_result_submissions
  SET status = 'confirmed',
      responded_by_club = v_club,
      responded_at = now()
  WHERE id = p_submission_id;

  UPDATE public.competition_inbox
  SET read_at = coalesce(read_at, now())
  WHERE submission_id = p_submission_id
    AND recipient_club_short_name = v_club
    AND message_type = 'result_to_confirm';

  SELECT "Club" INTO v_home_name FROM public."Clubs" WHERE "ShortName" = v_fixture.home_club_short_name;
  SELECT "Club" INTO v_away_name FROM public."Clubs" WHERE "ShortName" = v_fixture.away_club_short_name;

  v_label := CASE
    WHEN v_fixture.competition_type = 'cup' THEN public.competition_cup_fixture_label(v_fixture)
    ELSE format('Matchday %s', v_fixture.matchday)
  END;

  IF v_sub.et_home_goals IS NOT NULL THEN
    v_body := format(
      '%s — %s–%s confirmed (90 min %s–%s, after ET %s–%s).',
      v_label, v_home_total, v_away_total,
      v_sub.home_goals, v_sub.away_goals, v_sub.et_home_goals, v_sub.et_away_goals
    );
  ELSE
    v_body := format(
      '%s — %s–%s confirmed (90 min %s–%s).',
      v_label, v_home_total, v_away_total, v_sub.home_goals, v_sub.away_goals
    );
  END IF;

  IF v_sub.pen_winner_club_short_name IS NOT NULL THEN
    SELECT "Club" INTO v_pen_winner_name FROM public."Clubs" WHERE "ShortName" = v_sub.pen_winner_club_short_name;
    v_body := v_body || format(' Pens: %s won.', coalesce(v_pen_winner_name, v_sub.pen_winner_club_short_name));
  END IF;

  PERFORM public.competition_inbox_notify(
    v_sub.submitted_by_club,
    'result_confirmed',
    v_sub.fixture_id,
    p_submission_id,
    format('Result confirmed: %s vs %s', v_home_name, v_away_name),
    v_body
  );

  -- Clinch + bookies intentionally NOT run here (month lock / digest / admin reprice).
END;
$function$;

ALTER FUNCTION public.competition_confirm_result(bigint, jsonb)
  SET statement_timeout = '180s';

GRANT EXECUTE ON FUNCTION public.competition_confirm_result(bigint, jsonb) TO authenticated;

COMMENT ON FUNCTION public.competition_confirm_result(bigint, jsonb) IS
  'Confirm pending result with confirmer squad stats. statement_timeout 180s; skips clinch+bookies during played UPDATE; does not re-run them after.';

-- ---------------------------------------------------------------------------
-- Admin timed confirm (+ optional replay reset)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_test_confirm_pending_result(
  p_club_a text DEFAULT 'COR',
  p_club_b text DEFAULT 'JUB',
  p_matchday int DEFAULT 3,
  p_division text DEFAULT 'superleague',
  p_also_reset boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout = '180s'
AS $function$
DECLARE
  v_season bigint;
  v_sub public.competition_result_submissions;
  v_fixture public.competition_fixtures;
  v_confirmer text;
  v_expected int;
  v_stats jsonb;
  v_t0 timestamptz;
  v_t1 timestamptz;
  v_err text := NULL;
  v_reset jsonb := NULL;
  v_a text := upper(nullif(btrim(coalesce(p_club_a, '')), ''));
  v_b text := upper(nullif(btrim(coalesce(p_club_b, '')), ''));
  v_div text := lower(nullif(btrim(coalesce(p_division, '')), ''));
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '180s', true);

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  SELECT rs.*
  INTO v_sub
  FROM public.competition_result_submissions rs
  JOIN public.competition_fixtures f ON f.id = rs.fixture_id
  WHERE rs.status = 'pending'
    AND f.season_id = v_season
    AND coalesce(f.competition_type, 'league') = 'league'
    AND (v_div IS NULL OR f.division = v_div)
    AND (p_matchday IS NULL OR f.matchday = p_matchday)
    AND (
      (v_a IS NULL AND v_b IS NULL)
      OR (
        v_a IS NOT NULL AND v_b IS NOT NULL
        AND (
          (upper(btrim(f.home_club_short_name)) = v_a
           AND upper(btrim(f.away_club_short_name)) = v_b)
          OR (upper(btrim(f.home_club_short_name)) = v_b
              AND upper(btrim(f.away_club_short_name)) = v_a)
        )
      )
      OR (
        v_a IS NOT NULL AND v_b IS NULL
        AND v_a IN (
          upper(btrim(f.home_club_short_name)),
          upper(btrim(f.away_club_short_name))
        )
      )
    )
  ORDER BY rs.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'no_pending_submission',
      'hint', 'Check clubs/matchday/division or run admin_diagnose_pending_confirm'
    );
  END IF;

  SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = v_sub.fixture_id;

  v_confirmer := CASE
    WHEN upper(btrim(v_fixture.home_club_short_name)) = upper(btrim(v_sub.submitted_by_club))
      THEN upper(btrim(v_fixture.away_club_short_name))
    ELSE upper(btrim(v_fixture.home_club_short_name))
  END;

  v_expected := public.competition_expected_goals_for_club(v_fixture, v_sub, v_confirmer);

  IF to_regprocedure('public.admin_testing_build_club_match_stats(text,int,bigint)') IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'missing_admin_testing_build_club_match_stats',
      'fixture_id', v_fixture.id,
      'submission_id', v_sub.id
    );
  END IF;

  v_stats := public.admin_testing_build_club_match_stats(
    v_confirmer, v_expected, v_fixture.id
  );

  IF to_regprocedure('public.gpsl_sim_set_acting_club(text)') IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'missing_gpsl_sim_set_acting_club',
      'fixture_id', v_fixture.id
    );
  END IF;

  v_t0 := clock_timestamp();
  BEGIN
    PERFORM public.gpsl_sim_set_acting_club(v_confirmer);
    PERFORM public.competition_confirm_result(v_sub.id, v_stats);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  BEGIN
    PERFORM public.gpsl_sim_set_acting_club(NULL);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  v_t1 := clock_timestamp();

  IF v_err IS NULL AND p_also_reset THEN
    IF to_regprocedure(
         'public.admin_fixture_reset_for_replay(bigint,text,text)'
       ) IS NULL THEN
      v_reset := jsonb_build_object(
        'ok', false,
        'reason', 'missing_admin_fixture_reset_for_replay'
      );
    ELSE
      BEGIN
        v_reset := public.admin_fixture_reset_for_replay(
          v_fixture.id,
          'Admin timed confirm test — restore pending replay',
          'RESET FIXTURE REPLAY'
        );
      EXCEPTION WHEN OTHERS THEN
        v_reset := jsonb_build_object('ok', false, 'error', SQLERRM);
      END;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', v_err IS NULL,
    'error', v_err,
    'elapsed_ms', round(extract(epoch from (v_t1 - v_t0)) * 1000.0)::int,
    'fixture_id', v_fixture.id,
    'submission_id', v_sub.id,
    'submitted_by', v_sub.submitted_by_club,
    'confirmer', v_confirmer,
    'score', format('%s-%s', v_sub.home_goals, v_sub.away_goals),
    'division', v_fixture.division,
    'matchday', v_fixture.matchday,
    'home', v_fixture.home_club_short_name,
    'away', v_fixture.away_club_short_name,
    'reset', v_reset,
    'note', CASE
      WHEN v_err IS NULL AND p_also_reset THEN
        'Confirm path timed; fixture reset for replay (pending result cleared — Jubilo must re-submit to re-test UI).'
      WHEN v_err IS NULL THEN
        'Confirm OK — reset manually via admin_fixture_reset.html (phrase: RESET FIXTURE REPLAY).'
      ELSE
        'Confirm failed — fixture left as-is (still pending if rolled back).'
    END
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_test_confirm_pending_result(text, text, int, text, boolean)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_test_confirm_pending_result(text, text, int, text, boolean)
  TO authenticated;

COMMENT ON FUNCTION public.admin_test_confirm_pending_result(text, text, int, text, boolean) IS
  'Admin: act as confirmer club, time competition_confirm_result on a pending submission, optionally wipe via admin_fixture_reset_for_replay.';

NOTIFY pgrst, 'reload schema';
