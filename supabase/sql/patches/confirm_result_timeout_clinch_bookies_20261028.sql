-- =============================================================================
-- Fix: Match Day confirm → "Cancelling statement due to statement timeout"
--
-- Repro: Corinthians (gerrd1700) confirming SuperLeague MD3 vs Jubilo (rota66
-- submitted 3–0). Confirm RPC dies under the default PostgREST statement_timeout
-- because UPDATE … status='played' synchronously runs:
--   • competition_process_league_clinches (full season scan)
--   • admin_bookies_recompute_all_odds (full board reprice)
-- then still has to apply both clubs' stats, fitness/injuries, gates, TV, etc.
--
-- Fix:
--   • Raise statement_timeout to 120s on confirm
--   • Skip clinch + bookies reprice during the played UPDATE (session GUCs)
--   • Soft-run clinch + bookies after the result is safely confirmed
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Bookies: honour skip GUC (same pattern as gpsl.skip_clinch_scan)
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

-- ---------------------------------------------------------------------------
-- Discord played trigger: skip clinch when confirm sets the GUC
-- (clinch function also has its own skip guard; this avoids the call entirely)
-- ---------------------------------------------------------------------------
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

  -- Results go via gpsl_discord_results_digest_tick() (daily, by division/week).
  -- Clinch scan after league results only — skip during Match Day confirm.
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
-- competition_confirm_result — timeout + defer heavy side-effects
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_confirm_result(
  p_submission_id bigint,
  p_confirmer_player_stats jsonb DEFAULT '[]'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
  -- PostgREST default is often ~8s; confirm path exceeds that on busy seasons.
  PERFORM set_config('statement_timeout', '120s', true);
  -- Defer season-wide scans until after the result is written.
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

  IF to_regprocedure('public.competition_try_award_challenges(bigint,text)') IS NOT NULL THEN
    PERFORM public.competition_try_award_challenges(
      v_fixture.season_id, v_fixture.home_club_short_name
    );
    PERFORM public.competition_try_award_challenges(
      v_fixture.season_id, v_fixture.away_club_short_name
    );
  ELSIF to_regprocedure('public.competition_try_award_challenges(bigint,text,boolean)') IS NOT NULL THEN
    PERFORM public.competition_try_award_challenges(
      v_fixture.season_id, v_fixture.home_club_short_name, false
    );
    PERFORM public.competition_try_award_challenges(
      v_fixture.season_id, v_fixture.away_club_short_name, false
    );
  END IF;

  IF v_fixture.competition_type = 'cup' THEN
    PERFORM public.competition_cup_on_fixture_played(v_sub.fixture_id);
  ELSIF v_fixture.competition_type = 'league'
     AND to_regprocedure(
           'public.competition_try_pay_league_division_prizes(bigint,text)'
         ) IS NOT NULL THEN
    PERFORM public.competition_try_pay_league_division_prizes(
      v_fixture.season_id, v_fixture.division
    );
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

  -- Soft side-effects: never roll back a successful confirm
  PERFORM set_config('gpsl.skip_clinch_scan', 'off', true);
  PERFORM set_config('gpsl.skip_bookies_reprice', 'off', true);

  IF coalesce(v_fixture.competition_type, 'league') = 'league'
     AND nullif(btrim(coalesce(v_fixture.cup_code, '')), '') IS NULL
     AND to_regprocedure('public.competition_process_league_clinches(bigint)') IS NOT NULL THEN
    BEGIN
      PERFORM public.competition_process_league_clinches(v_fixture.season_id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'clinch after confirm fixture % failed: %', v_fixture.id, SQLERRM;
    END;
  END IF;

  IF to_regprocedure('public.admin_bookies_recompute_all_odds(bigint)') IS NOT NULL THEN
    BEGIN
      PERFORM public.admin_bookies_recompute_all_odds(v_fixture.season_id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'bookies after confirm fixture % failed: %', v_fixture.id, SQLERRM;
    END;
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_confirm_result(bigint, jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- Diagnose helper for pending COR / JUB (or any) confirm timeout cases
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_diagnose_pending_confirm(
  p_home text DEFAULT NULL,
  p_away text DEFAULT NULL,
  p_matchday int DEFAULT NULL,
  p_division text DEFAULT 'superleague'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_rows jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.fixture_id), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      f.id AS fixture_id,
      f.division,
      f.matchday,
      f.home_club_short_name,
      f.away_club_short_name,
      f.status AS fixture_status,
      f.home_goals,
      f.away_goals,
      rs.id AS submission_id,
      rs.status AS submission_status,
      rs.submitted_by_club,
      rs.home_goals AS proposed_home,
      rs.away_goals AS proposed_away,
      rs.submitted_at,
      (
        SELECT count(*)::int
        FROM public.competition_match_player_stats s
        WHERE s.fixture_id = f.id
          AND s.club_short_name = rs.submitted_by_club
      ) AS submitter_stat_rows,
      (
        SELECT count(*)::int
        FROM public.competition_match_player_stats s
        WHERE s.fixture_id = f.id
          AND s.club_short_name <> rs.submitted_by_club
      ) AS confirmer_stat_rows
    FROM public.competition_fixtures f
    JOIN public.competition_result_submissions rs
      ON rs.fixture_id = f.id
     AND rs.status = 'pending'
    WHERE f.season_id = v_season
      AND coalesce(f.competition_type, 'league') = 'league'
      AND (p_division IS NULL OR f.division = lower(btrim(p_division)))
      AND (p_matchday IS NULL OR f.matchday = p_matchday)
      AND (
        p_home IS NULL
        OR f.home_club_short_name = upper(btrim(p_home))
        OR f.away_club_short_name = upper(btrim(p_home))
      )
      AND (
        p_away IS NULL
        OR f.home_club_short_name = upper(btrim(p_away))
        OR f.away_club_short_name = upper(btrim(p_away))
      )
  ) x;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season,
    'pending', v_rows
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_diagnose_pending_confirm(text, text, int, text)
  TO authenticated;

COMMENT ON FUNCTION public.competition_confirm_result(bigint, jsonb) IS
  'Confirm a pending result with confirmer squad stats. Raises statement_timeout to 120s; defers clinch + bookies reprice until after confirm.';

COMMENT ON FUNCTION public.admin_diagnose_pending_confirm(text, text, int, text) IS
  'Admin: list pending result submissions (e.g. COR vs JUB SuperLeague MD3).';

NOTIFY pgrst, 'reload schema';
