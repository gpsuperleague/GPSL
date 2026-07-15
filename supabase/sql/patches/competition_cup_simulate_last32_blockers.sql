-- =============================================================================
-- One-shot: simulate the 3 Last 32 ties blocking Last 16 (season 4 diagnose)
--   CHE vs MCI  → fixture 3626
--   LYO vs PSV  → fixture 3627
--   BRU vs BES  → fixture 3628
--
-- Run entire file in Supabase SQL Editor (postgres).
-- Re-run safe: already-played fixtures are skipped.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_cup_simulate_fixture_ids(
  p_fixture_ids bigint[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_results jsonb := '[]'::jsonb;
  v_one jsonb;
  v_skipped jsonb := '[]'::jsonb;
  v_errors jsonb := '[]'::jsonb;
  v_fx public.competition_fixtures;
  v_fill jsonb;
  v_home_stats jsonb;
  v_away_stats jsonb;
  v_home_goals smallint;
  v_away_goals smallint;
  v_pen_winner text;
  v_cup_roll jsonb;
  v_score_label text;
  v_gate_err text;
  v_prize_err text;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_fixture_ids IS NULL OR coalesce(array_length(p_fixture_ids, 1), 0) = 0 THEN
    RAISE EXCEPTION 'Provide at least one fixture id';
  END IF;

  FOREACH v_id IN ARRAY p_fixture_ids LOOP
    SELECT * INTO v_fx
    FROM public.competition_fixtures
    WHERE id = v_id
    FOR UPDATE;

    IF NOT FOUND THEN
      v_errors := v_errors || jsonb_build_array(
        jsonb_build_object('fixture_id', v_id, 'error', 'not found')
      );
      CONTINUE;
    END IF;

    IF v_fx.status = 'played' THEN
      v_skipped := v_skipped || jsonb_build_array(
        jsonb_build_object(
          'fixture_id', v_id,
          'home_club', v_fx.home_club_short_name,
          'away_club', v_fx.away_club_short_name,
          'score', format('%s-%s', v_fx.home_goals, v_fx.away_goals),
          'reason', 'already played'
        )
      );
      CONTINUE;
    END IF;

    IF v_fx.status IS DISTINCT FROM 'scheduled' THEN
      v_errors := v_errors || jsonb_build_array(
        jsonb_build_object(
          'fixture_id', v_id,
          'error', format('status=%s (need scheduled)', v_fx.status)
        )
      );
      CONTINUE;
    END IF;

    IF v_fx.competition_type IS DISTINCT FROM 'cup' THEN
      v_errors := v_errors || jsonb_build_array(
        jsonb_build_object('fixture_id', v_id, 'error', 'not a cup fixture')
      );
      CONTINUE;
    END IF;

    BEGIN
      IF NOT public.admin_testing_fixture_squads_ready(
        v_fx.home_club_short_name,
        v_fx.away_club_short_name,
        v_id
      ) THEN
        RAISE EXCEPTION 'Squad too small — % (% avail) vs % (% avail)',
          v_fx.home_club_short_name,
          public.admin_testing_club_available_count(v_fx.home_club_short_name, v_id),
          v_fx.away_club_short_name,
          public.admin_testing_club_available_count(v_fx.away_club_short_name, v_id);
      END IF;

      UPDATE public.competition_result_submissions
      SET status = 'rejected',
          reject_reason = 'Superseded by cup fixture simulate SQL',
          responded_by_club = NULL,
          responded_at = now()
      WHERE fixture_id = v_id
        AND status = 'pending';

      UPDATE public.competition_inbox
      SET read_at = coalesce(read_at, now())
      WHERE fixture_id = v_id
        AND message_type = 'result_to_confirm';

      v_cup_roll := public.admin_testing_roll_cup_open_play();
      v_home_goals := (v_cup_roll->>'home_open')::smallint;
      v_away_goals := (v_cup_roll->>'away_open')::smallint;
      v_gate_err := NULL;
      v_prize_err := NULL;

      IF v_cup_roll->>'pen_slot' = 'home' THEN
        v_pen_winner := v_fx.home_club_short_name;
        v_score_label := format(
          '%s-%s aet pens (%s)',
          v_cup_roll->>'home_90',
          v_cup_roll->>'away_90',
          v_fx.home_club_short_name
        );
      ELSIF v_cup_roll->>'pen_slot' = 'away' THEN
        v_pen_winner := v_fx.away_club_short_name;
        v_score_label := format(
          '%s-%s aet pens (%s)',
          v_cup_roll->>'home_90',
          v_cup_roll->>'away_90',
          v_fx.away_club_short_name
        );
      ELSIF (v_cup_roll->>'home_open')::int <> (v_cup_roll->>'home_90')::int
         OR (v_cup_roll->>'away_open')::int <> (v_cup_roll->>'away_90')::int THEN
        v_pen_winner := NULL;
        v_score_label := format(
          '%s-%s (%s-%s aet)',
          v_cup_roll->>'home_90',
          v_cup_roll->>'away_90',
          v_home_goals,
          v_away_goals
        );
      ELSE
        v_pen_winner := NULL;
        v_score_label := format('%s-%s', v_home_goals, v_away_goals);
      END IF;

      v_home_stats := public.admin_testing_build_club_match_stats(
        v_fx.home_club_short_name,
        CASE WHEN v_pen_winner IS NOT NULL
          THEN (v_cup_roll->>'home_90')::int ELSE v_home_goals::int END,
        v_id
      );
      v_away_stats := public.admin_testing_build_club_match_stats(
        v_fx.away_club_short_name,
        CASE WHEN v_pen_winner IS NOT NULL
          THEN (v_cup_roll->>'away_90')::int ELSE v_away_goals::int END,
        v_id
      );

      UPDATE public.competition_fixtures
      SET home_goals = v_home_goals,
          away_goals = v_away_goals,
          cup_pen_winner_club_short_name = v_pen_winner,
          status = 'played'
      WHERE id = v_id;

      PERFORM public.competition_apply_club_player_stats(
        v_fx.id,
        v_fx.season_id,
        v_fx.home_club_short_name,
        v_home_stats,
        CASE WHEN v_pen_winner IS NOT NULL
          THEN (v_cup_roll->>'home_90')::int ELSE v_home_goals::int END
      );
      PERFORM public.competition_apply_club_player_stats(
        v_fx.id,
        v_fx.season_id,
        v_fx.away_club_short_name,
        v_away_stats,
        CASE WHEN v_pen_winner IS NOT NULL
          THEN (v_cup_roll->>'away_90')::int ELSE v_away_goals::int END
      );

      BEGIN
        PERFORM public.competition_settle_fixture_gates(v_id);
      EXCEPTION WHEN OTHERS THEN
        v_gate_err := SQLERRM;
      END;

      BEGIN
        PERFORM public.competition_cup_on_fixture_played(v_id);
      EXCEPTION WHEN OTHERS THEN
        v_prize_err := SQLERRM;
      END;

      BEGIN
        PERFORM public.competition_pay_cup_fixture_prizes(v_id);
      EXCEPTION WHEN OTHERS THEN
        v_prize_err := coalesce(v_prize_err, SQLERRM);
      END;

      v_one := jsonb_build_object(
        'ok', true,
        'fixture_id', v_id,
        'home_club', v_fx.home_club_short_name,
        'away_club', v_fx.away_club_short_name,
        'score', v_score_label,
        'pen_winner', v_pen_winner,
        'gate_warning', v_gate_err,
        'prize_warning', v_prize_err
      );
      v_results := v_results || jsonb_build_array(v_one);
    EXCEPTION
      WHEN OTHERS THEN
        v_errors := v_errors || jsonb_build_array(
          jsonb_build_object('fixture_id', v_id, 'error', SQLERRM)
        );
    END;
  END LOOP;

  IF to_regprocedure('public.competition_cup_repair_force_fill(bigint, text)') IS NOT NULL THEN
    v_fill := public.competition_cup_repair_force_fill(NULL, 'league_cup');
  ELSE
    v_fill := jsonb_build_object(
      'ok', false,
      'note', 'Run competition_cup_repair_force_fill.sql then Force fill'
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', jsonb_array_length(v_errors) = 0,
    'simulated', v_results,
    'skipped', v_skipped,
    'errors', v_errors,
    'force_fill', v_fill
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_cup_simulate_fixture_ids(bigint[]) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Simulate the three blockers + force-fill Last 16 slots
SELECT public.competition_cup_simulate_fixture_ids(ARRAY[3626, 3627, 3628]::bigint[]);
