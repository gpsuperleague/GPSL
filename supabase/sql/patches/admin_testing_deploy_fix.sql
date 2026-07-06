-- =============================================================================
-- Admin testing deploy — league + cup, clearer errors, resilient settlement
-- Run after admin_testing_tools.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_testing_fixture_squads_ready(
  p_home_club text,
  p_away_club text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.club_squad_player_count(p_home_club) >= 11
     AND public.club_squad_player_count(p_away_club) >= 11;
$$;

-- Random cup outcome: 90-min score, optional ET totals or penalties on draws
CREATE OR REPLACE FUNCTION public.admin_testing_roll_cup_open_play()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SET search_path = public
AS $function$
DECLARE
  v_h90 smallint := floor(random() * 5)::smallint;
  v_a90 smallint := floor(random() * 5)::smallint;
  v_home_open smallint;
  v_away_open smallint;
  v_pen text;
  v_home_club text;
  v_away_club text;
BEGIN
  IF v_h90 > v_a90 THEN
    v_home_open := v_h90;
    v_away_open := v_a90;
    v_pen := NULL;
  ELSIF v_a90 > v_h90 THEN
    v_home_open := v_h90;
    v_away_open := v_a90;
    v_pen := NULL;
  ELSIF random() < 0.45 THEN
  -- Extra time — cumulative totals, must exceed 90-min draw
    v_home_open := v_h90;
    v_away_open := v_a90;
    IF random() < 0.5 THEN
      v_home_open := (v_h90 + 1 + floor(random() * 2)::int)::smallint;
    ELSE
      v_away_open := (v_a90 + 1 + floor(random() * 2)::int)::smallint;
    END IF;
    IF v_home_open = v_away_open THEN
      v_home_open := v_home_open + 1;
    END IF;
    v_pen := NULL;
  ELSE
  -- Penalties after level 90 minutes
    v_home_open := v_h90;
    v_away_open := v_a90;
    v_pen := CASE WHEN random() < 0.5 THEN 'home' ELSE 'away' END;
  END IF;

  RETURN jsonb_build_object(
    'home_90', v_h90,
    'away_90', v_a90,
    'home_open', v_home_open,
    'away_open', v_away_open,
    'pen_slot', v_pen
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_testing_deploy_scheduled_fixture(
  p_fixture_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_home_stats jsonb;
  v_away_stats jsonb;
  v_home_goals smallint;
  v_away_goals smallint;
  v_pen_winner text;
  v_cup_roll jsonb;
  v_gate_err text;
  v_prize_err text;
  v_score_label text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture % is not scheduled (status=%)', p_fixture_id, v_fixture.status;
  END IF;

  IF v_fixture.competition_type NOT IN ('league', 'cup') THEN
    RAISE EXCEPTION 'Unsupported competition_type=%', v_fixture.competition_type;
  END IF;

  IF NOT public.admin_testing_fixture_squads_ready(
    v_fixture.home_club_short_name,
    v_fixture.away_club_short_name
  ) THEN
    RAISE EXCEPTION 'Squad too small — %s (%s) vs %s (%s)',
      v_fixture.home_club_short_name,
      public.club_squad_player_count(v_fixture.home_club_short_name),
      v_fixture.away_club_short_name,
      public.club_squad_player_count(v_fixture.away_club_short_name);
  END IF;

  UPDATE public.competition_result_submissions
  SET status = 'rejected',
      reject_reason = 'Superseded by admin testing month deploy',
      responded_by_club = NULL,
      responded_at = now()
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  UPDATE public.competition_inbox
  SET read_at = coalesce(read_at, now())
  WHERE fixture_id = p_fixture_id
    AND message_type = 'result_to_confirm';

  IF v_fixture.competition_type = 'league' THEN
    v_home_goals := floor(random() * 5)::smallint;
    v_away_goals := floor(random() * 5)::smallint;
    v_pen_winner := NULL;
    v_score_label := format('%s-%s', v_home_goals, v_away_goals);
  ELSE
    v_cup_roll := public.admin_testing_roll_cup_open_play();
    v_home_goals := (v_cup_roll->>'home_open')::smallint;
    v_away_goals := (v_cup_roll->>'away_open')::smallint;
  -- Player stats use open-play goals each team scored (90-min base for pen shootouts)
    IF v_cup_roll->>'pen_slot' = 'home' THEN
      v_pen_winner := v_fixture.home_club_short_name;
      v_score_label := format(
        '%s-%s aet pens (%s)',
        v_cup_roll->>'home_90',
        v_cup_roll->>'away_90',
        v_fixture.home_club_short_name
      );
    ELSIF v_cup_roll->>'pen_slot' = 'away' THEN
      v_pen_winner := v_fixture.away_club_short_name;
      v_score_label := format(
        '%s-%s aet pens (%s)',
        v_cup_roll->>'home_90',
        v_cup_roll->>'away_90',
        v_fixture.away_club_short_name
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
  END IF;

  v_home_stats := public.admin_testing_build_club_match_stats(
    v_fixture.home_club_short_name,
    CASE
      WHEN v_fixture.competition_type = 'cup' AND v_pen_winner IS NOT NULL
        THEN (v_cup_roll->>'home_90')::int
      ELSE v_home_goals::int
    END
  );
  v_away_stats := public.admin_testing_build_club_match_stats(
    v_fixture.away_club_short_name,
    CASE
      WHEN v_fixture.competition_type = 'cup' AND v_pen_winner IS NOT NULL
        THEN (v_cup_roll->>'away_90')::int
      ELSE v_away_goals::int
    END
  );

  UPDATE public.competition_fixtures
  SET home_goals = v_home_goals,
      away_goals = v_away_goals,
      cup_pen_winner_club_short_name = v_pen_winner,
      status = 'played'
  WHERE id = p_fixture_id;

  PERFORM public.competition_apply_club_player_stats(
    v_fixture.id,
    v_fixture.season_id,
    v_fixture.home_club_short_name,
    v_home_stats,
    CASE
      WHEN v_fixture.competition_type = 'cup' AND v_pen_winner IS NOT NULL
        THEN (v_cup_roll->>'home_90')::int
      ELSE v_home_goals::int
    END
  );
  PERFORM public.competition_apply_club_player_stats(
    v_fixture.id,
    v_fixture.season_id,
    v_fixture.away_club_short_name,
    v_away_stats,
    CASE
      WHEN v_fixture.competition_type = 'cup' AND v_pen_winner IS NOT NULL
        THEN (v_cup_roll->>'away_90')::int
      ELSE v_away_goals::int
    END
  );

  BEGIN
    PERFORM public.competition_settle_fixture_gates(p_fixture_id);
  EXCEPTION
    WHEN OTHERS THEN
      v_gate_err := SQLERRM;
  END;

  IF v_fixture.competition_type = 'league' THEN
    BEGIN
      PERFORM public.competition_try_pay_league_division_prizes(
        v_fixture.season_id,
        v_fixture.division
      );
    EXCEPTION
      WHEN OTHERS THEN
        v_prize_err := SQLERRM;
    END;
  ELSE
    BEGIN
      PERFORM public.competition_cup_on_fixture_played(p_fixture_id);
    EXCEPTION
      WHEN OTHERS THEN
        v_prize_err := SQLERRM;
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'competition_type', v_fixture.competition_type,
    'cup_code', v_fixture.cup_code,
    'cup_round', v_fixture.cup_round,
    'home_club', v_fixture.home_club_short_name,
    'away_club', v_fixture.away_club_short_name,
    'score', v_score_label,
    'pen_winner', v_pen_winner,
    'matchday', v_fixture.matchday,
    'gpsl_month', v_fixture.gpsl_month,
    'gate_warning', v_gate_err,
    'prize_warning', v_prize_err
  );
END;
$function$;

-- Legacy entry point — explicit league scores (cups: use deploy_scheduled_fixture)
CREATE OR REPLACE FUNCTION public.admin_testing_deploy_fixture_result(
  p_fixture_id bigint,
  p_home_goals smallint,
  p_away_goals smallint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_home_stats jsonb;
  v_away_stats jsonb;
  v_gate_err text;
  v_prize_err text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_home_goals IS NULL OR p_away_goals IS NULL OR p_home_goals < 0 OR p_away_goals < 0 THEN
    RAISE EXCEPTION 'Invalid score';
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  IF v_fixture.competition_type = 'cup' THEN
    RETURN public.admin_testing_deploy_scheduled_fixture(p_fixture_id);
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture % is not scheduled (status=%)', p_fixture_id, v_fixture.status;
  END IF;

  UPDATE public.competition_result_submissions
  SET status = 'rejected',
      reject_reason = 'Superseded by admin testing month deploy',
      responded_by_club = NULL,
      responded_at = now()
  WHERE fixture_id = p_fixture_id
    AND status = 'pending';

  UPDATE public.competition_inbox
  SET read_at = coalesce(read_at, now())
  WHERE fixture_id = p_fixture_id
    AND message_type = 'result_to_confirm';

  v_home_stats := public.admin_testing_build_club_match_stats(
    v_fixture.home_club_short_name,
    p_home_goals::int
  );
  v_away_stats := public.admin_testing_build_club_match_stats(
    v_fixture.away_club_short_name,
    p_away_goals::int
  );

  UPDATE public.competition_fixtures
  SET home_goals = p_home_goals,
      away_goals = p_away_goals,
      cup_pen_winner_club_short_name = NULL,
      status = 'played'
  WHERE id = p_fixture_id;

  PERFORM public.competition_apply_club_player_stats(
    v_fixture.id, v_fixture.season_id, v_fixture.home_club_short_name,
    v_home_stats, p_home_goals::int
  );
  PERFORM public.competition_apply_club_player_stats(
    v_fixture.id, v_fixture.season_id, v_fixture.away_club_short_name,
    v_away_stats, p_away_goals::int
  );

  BEGIN
    PERFORM public.competition_settle_fixture_gates(p_fixture_id);
  EXCEPTION WHEN OTHERS THEN
    v_gate_err := SQLERRM;
  END;

  BEGIN
    PERFORM public.competition_try_pay_league_division_prizes(
      v_fixture.season_id, v_fixture.division
    );
  EXCEPTION WHEN OTHERS THEN
    v_prize_err := SQLERRM;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'competition_type', 'league',
    'home_club', v_fixture.home_club_short_name,
    'away_club', v_fixture.away_club_short_name,
    'score', format('%s-%s', p_home_goals, p_away_goals),
    'matchday', v_fixture.matchday,
    'gpsl_month', v_fixture.gpsl_month,
    'gate_warning', v_gate_err,
    'prize_warning', v_prize_err
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_testing_deploy_month_preview(
  p_gpsl_month text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(trim(p_gpsl_month));
  v_season_id bigint;
  v_fixtures jsonb;
  v_league_ready int := 0;
  v_cup_ready int := 0;
  v_blocked int := 0;
  v_under_11 jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_month IS NULL OR v_month = '' THEN
    RAISE EXCEPTION 'GPSL month is required';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current competition season';
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(t)::jsonb ORDER BY t.sort_key, t.id), '[]'::jsonb)
  INTO v_fixtures
  FROM (
    SELECT
      f.id,
      f.matchday,
      f.division,
      f.gpsl_month,
      f.cup_code,
      f.cup_round,
      f.cup_match,
      f.home_club_short_name AS home_club,
      f.away_club_short_name AS away_club,
      f.status,
      f.competition_type,
      public.club_squad_player_count(f.home_club_short_name) AS home_squad_size,
      public.club_squad_player_count(f.away_club_short_name) AS away_squad_size,
      (
        f.status = 'scheduled'
        AND f.competition_type IN ('league', 'cup')
        AND public.admin_testing_fixture_squads_ready(
          f.home_club_short_name,
          f.away_club_short_name
        )
      ) AS ready,
      CASE
        WHEN f.status <> 'scheduled' THEN format('status=%s', f.status)
        WHEN f.competition_type NOT IN ('league', 'cup') THEN f.competition_type
        WHEN public.club_squad_player_count(f.home_club_short_name) < 11 THEN
          format('home %s has %s players (need 11)', f.home_club_short_name, public.club_squad_player_count(f.home_club_short_name))
        WHEN public.club_squad_player_count(f.away_club_short_name) < 11 THEN
          format('away %s has %s players (need 11)', f.away_club_short_name, public.club_squad_player_count(f.away_club_short_name))
        ELSE 'ready'
      END AS block_reason,
      CASE f.competition_type
        WHEN 'cup' THEN coalesce(f.cup_code, 'cup') || ':R' || coalesce(f.cup_round::text, '?')
        ELSE coalesce(f.division, 'league')
      END AS sort_key
    FROM public.competition_fixtures f
    WHERE f.season_id = v_season_id
      AND f.gpsl_month = v_month
    ORDER BY
      CASE f.competition_type WHEN 'league' THEN 0 ELSE 1 END,
      f.cup_code NULLS FIRST,
      f.cup_round NULLS FIRST,
      f.cup_match NULLS FIRST,
      f.matchday,
      f.division,
      f.id
  ) t;

  SELECT
    count(*) FILTER (WHERE (elem ->> 'ready')::boolean AND elem ->> 'competition_type' = 'league'),
    count(*) FILTER (WHERE (elem ->> 'ready')::boolean AND elem ->> 'competition_type' = 'cup'),
    count(*) FILTER (WHERE NOT coalesce((elem ->> 'ready')::boolean, false))
  INTO v_league_ready, v_cup_ready, v_blocked
  FROM jsonb_array_elements(v_fixtures) elem;

  SELECT coalesce(jsonb_agg(row_data ORDER BY squad_size, club_short), '[]'::jsonb)
  INTO v_under_11
  FROM (
    SELECT
      jsonb_build_object(
        'club_short', c."ShortName",
        'club_name', c."Club",
        'squad_size', public.club_squad_player_count(c."ShortName")
      ) AS row_data,
      c."ShortName" AS club_short,
      public.club_squad_player_count(c."ShortName") AS squad_size
    FROM public."Clubs" c
    WHERE c.owner_id IS NOT NULL
      AND public.club_squad_player_count(c."ShortName") < 11
  ) q;

  RETURN jsonb_build_object(
    'gpsl_month', v_month,
    'gpsl_month_label', public.competition_gpsl_month_label(v_month),
    'season_id', v_season_id,
    'fixtures', v_fixtures,
    'scheduled_league_ready', v_league_ready,
    'scheduled_cup_ready', v_cup_ready,
    'scheduled_total_ready', v_league_ready + v_cup_ready,
    'blocked_or_other', v_blocked,
    'clubs_under_11', v_under_11,
    'confirm_phrase', 'DEPLOY TEST MONTH'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_testing_deploy_month_results(
  p_gpsl_month text,
  p_confirm_phrase text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(trim(p_gpsl_month));
  v_season_id bigint;
  v_fixture record;
  v_deployed jsonb := '[]'::jsonb;
  v_errors jsonb := '[]'::jsonb;
  v_error_summary jsonb := '{}'::jsonb;
  v_result jsonb;
  v_league_deployed int := 0;
  v_cup_deployed int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF coalesce(trim(p_confirm_phrase), '') <> 'DEPLOY TEST MONTH' THEN
    RAISE EXCEPTION 'Confirmation phrase required — type exactly: DEPLOY TEST MONTH';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current competition season';
  END IF;

  FOR v_fixture IN
    SELECT f.*
    FROM public.competition_fixtures f
    WHERE f.season_id = v_season_id
      AND f.gpsl_month = v_month
      AND f.status = 'scheduled'
      AND f.competition_type IN ('league', 'cup')
    ORDER BY
      CASE f.competition_type WHEN 'league' THEN 0 ELSE 1 END,
      f.cup_code NULLS FIRST,
      f.cup_round NULLS FIRST,
      f.cup_match NULLS FIRST,
      f.matchday,
      f.division,
      f.id
  LOOP
    BEGIN
      v_result := public.admin_testing_deploy_scheduled_fixture(v_fixture.id);
      v_deployed := v_deployed || jsonb_build_array(v_result);
      IF v_fixture.competition_type = 'cup' THEN
        v_cup_deployed := v_cup_deployed + 1;
      ELSE
        v_league_deployed := v_league_deployed + 1;
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'fixture_id', v_fixture.id,
          'competition_type', v_fixture.competition_type,
          'cup_code', v_fixture.cup_code,
          'error', SQLERRM
        ));
    END;
  END LOOP;

  SELECT coalesce(jsonb_object_agg(err, cnt), '{}'::jsonb)
  INTO v_error_summary
  FROM (
    SELECT elem ->> 'error' AS err, count(*)::int AS cnt
    FROM jsonb_array_elements(v_errors) elem
    GROUP BY 1
  ) s;

  RETURN jsonb_build_object(
    'ok', true,
    'gpsl_month', v_month,
    'gpsl_month_label', public.competition_gpsl_month_label(v_month),
    'season_id', v_season_id,
    'deployed_count', jsonb_array_length(v_deployed),
    'league_deployed_count', v_league_deployed,
    'cup_deployed_count', v_cup_deployed,
    'error_count', jsonb_array_length(v_errors),
    'error_summary', v_error_summary,
    'deployed', v_deployed,
    'errors', v_errors
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_testing_fixture_squads_ready(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_testing_roll_cup_open_play() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_testing_deploy_scheduled_fixture(bigint) TO authenticated;
