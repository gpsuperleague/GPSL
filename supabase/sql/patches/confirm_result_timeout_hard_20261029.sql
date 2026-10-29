-- =============================================================================
-- HARD FIX: competition_confirm_result statement timeout
--
-- UI: "canceling statement due to statement timeout" on Confirm result.
--
-- Fix:
--   • Function statement_timeout = 180s
--   • Skip clinch + bookies during confirm (no end soft-run)
--   • Soft-wrap challenges / league prizes
--   • Defer fitness tick + injury roll to soft tail after confirm succeeds
--
-- Safe re-run. Apply, check verify rows at bottom, retry Confirm as Jubilo.
-- =============================================================================

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

-- Defer guard: skip fitness tick + injury roll when gpsl.defer_injury_fitness=on
DO $$
DECLARE
  v_oid oid;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  v_oid := to_regprocedure('public.competition_serve_injuries_for_fixture(bigint)');
  IF v_oid IS NULL THEN
    RAISE NOTICE 'serve_injuries missing — skip defer inject';
    RETURN;
  END IF;

  v_def := pg_get_functiondef(v_oid);
  IF position('gpsl.defer_injury_fitness' IN v_def) > 0 THEN
    RAISE NOTICE 'serve_injuries already defers fitness';
    RETURN;
  END IF;

  v_old :=
    'IF v_fixture.id IS NOT NULL'
    || E'\n'
    || '     AND to_regprocedure(''public.competition_match_fitness_tick_club(bigint,text)'') IS NOT NULL THEN';

  IF position(v_old IN v_def) = 0 THEN
    -- older body without to_regprocedure guard
    v_old := 'IF v_fixture.id IS NOT NULL THEN';
  END IF;

  IF position(v_old IN v_def) = 0 THEN
    RAISE NOTICE 'serve_injuries body shape unexpected — skip defer inject';
    RETURN;
  END IF;

  v_new :=
    'IF current_setting(''gpsl.defer_injury_fitness'', true) = ''on'' THEN'
    || E'\n'
    || '    RETURN;'
    || E'\n'
    || '  END IF;'
    || E'\n'
    || E'\n'
    || '  '
    || v_old;

  v_def := replace(v_def, v_old, v_new);
  EXECUTE v_def;
  RAISE NOTICE 'serve_injuries: defer_injury_fitness guard installed';
END $$;

CREATE OR REPLACE FUNCTION public.competition_confirm_result(
  p_submission_id bigint,
  p_confirmer_player_stats jsonb DEFAULT '[]'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET statement_timeout TO '180s'
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
  PERFORM set_config('gpsl.defer_injury_fitness', 'on', true);

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
      RAISE WARNING 'challenges after confirm %: %', v_fixture.id, SQLERRM;
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
      RAISE WARNING 'challenges after confirm %: %', v_fixture.id, SQLERRM;
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
      RAISE WARNING 'league prizes after confirm %: %', v_fixture.id, SQLERRM;
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

  -- Soft tail: fitness + injury roll (cannot undo confirm)
  PERFORM set_config('gpsl.defer_injury_fitness', 'off', true);
  IF to_regprocedure('public.competition_serve_injuries_for_fixture(bigint)') IS NOT NULL THEN
    BEGIN
      PERFORM public.competition_serve_injuries_for_fixture(v_fixture.id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'deferred injury/fitness after confirm %: %', v_fixture.id, SQLERRM;
    END;
  END IF;
END;
$function$;

ALTER FUNCTION public.competition_confirm_result(bigint, jsonb)
  SET statement_timeout TO '180s';

GRANT EXECUTE ON FUNCTION public.competition_confirm_result(bigint, jsonb) TO authenticated;

COMMENT ON FUNCTION public.competition_confirm_result(bigint, jsonb) IS
  'Confirm result. statement_timeout 180s; skips clinch/bookies; defers fitness/injury-roll to soft tail.';

SELECT
  p.proname,
  (
    SELECT option_value
    FROM pg_options_to_table(p.proconfig) AS opt(option_name, option_value)
    WHERE opt.option_name = 'statement_timeout'
    LIMIT 1
  ) AS statement_timeout_setting,
  position('gpsl.skip_clinch_scan' IN pg_get_functiondef(p.oid)) > 0 AS skips_clinch,
  position('gpsl.defer_injury_fitness' IN pg_get_functiondef(p.oid)) > 0 AS defers_fitness
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'competition_confirm_result'
  AND pg_get_function_identity_arguments(p.oid) = 'bigint, jsonb';

NOTIFY pgrst, 'reload schema';
