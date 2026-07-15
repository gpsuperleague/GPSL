-- =============================================================================
-- Admin deploy month: seed yellow / red cards after a full month is deployed
--
-- Cards were NOT included in auto match stats (only goals/assists/POTM).
-- When a GPSL month has no remaining scheduled league/cup fixtures, assign:
--   • 1 red card total (random club/player among that month's played XI)
--   • 15 yellow cards total (randomly distributed)
--
-- Idempotent: only fills up to the targets (won't double if re-run).
-- Safe re-run. Run after admin_testing_deploy_skip_unavailable.sql.
-- =============================================================================

-- Include card flags (false) in generated XI stats for clarity
CREATE OR REPLACE FUNCTION public.admin_testing_build_club_match_stats(
  p_club text,
  p_expected_goals int,
  p_fixture_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SET search_path = public
AS $function$
DECLARE
  v_players text[];
  v_n int;
  v_sub_count int;
  v_potm_player text;
  v_assist_total int;
  i int;
BEGIN
  IF p_expected_goals IS NULL OR p_expected_goals < 0 THEN
    RAISE EXCEPTION 'Invalid expected goals';
  END IF;

  SELECT coalesce(array_agg(p."Konami_ID"::text ORDER BY random()), ARRAY[]::text[])
  INTO v_players
  FROM public."Players" p
  WHERE p."Contracted_Team" = p_club
    AND (
      p_fixture_id IS NULL
      OR public.competition_player_unavailable_for_fixture(
        p_fixture_id,
        p."Konami_ID"::text
      ) IS NULL
    );

  v_n := coalesce(array_length(v_players, 1), 0);
  IF v_n < 11 THEN
    RAISE EXCEPTION
      'Club % has only % available players for fixture % (need 11; injured/suspended excluded)',
      p_club, v_n, coalesce(p_fixture_id::text, 'n/a');
  END IF;

  DROP TABLE IF EXISTS _admin_test_stats;
  CREATE TEMP TABLE _admin_test_stats (
    player_id text PRIMARY KEY,
    started boolean NOT NULL DEFAULT false,
    subbed_on boolean NOT NULL DEFAULT false,
    goals int NOT NULL DEFAULT 0,
    assists int NOT NULL DEFAULT 0,
    potm boolean NOT NULL DEFAULT false
  ) ON COMMIT DROP;

  INSERT INTO _admin_test_stats (player_id, started)
  SELECT unnest(v_players[1:11]), true;

  v_sub_count := least(5, v_n - 11);
  IF v_sub_count > 0 THEN
    v_sub_count := floor(random() * (v_sub_count + 1))::int;
    IF v_sub_count > 0 THEN
      INSERT INTO _admin_test_stats (player_id, subbed_on)
      SELECT unnest(v_players[12:11 + v_sub_count]), true;
    END IF;
  END IF;

  SELECT s.player_id
  INTO v_potm_player
  FROM _admin_test_stats s
  WHERE s.started
  ORDER BY random()
  LIMIT 1;

  UPDATE _admin_test_stats
  SET potm = (player_id = v_potm_player)
  WHERE started OR subbed_on;

  FOR i IN 1..p_expected_goals LOOP
    UPDATE _admin_test_stats
    SET goals = goals + 1
    WHERE player_id = (
      SELECT s.player_id FROM _admin_test_stats s ORDER BY random() LIMIT 1
    );
  END LOOP;

  v_assist_total := CASE
    WHEN p_expected_goals > 0 THEN floor(random() * (p_expected_goals + 1))::int
    ELSE 0
  END;

  FOR i IN 1..v_assist_total LOOP
    UPDATE _admin_test_stats
    SET assists = assists + 1
    WHERE player_id = (
      SELECT s.player_id FROM _admin_test_stats s ORDER BY random() LIMIT 1
    );
  END LOOP;

  RETURN (
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'player_id', s.player_id,
          'started', s.started,
          'subbed_on', s.subbed_on,
          'goals', s.goals,
          'assists', s.assists,
          'rating', 6.0,
          'potm', s.potm,
          'yellow_card', false,
          'red_card', false
        )
        ORDER BY s.started DESC, s.player_id
      ),
      '[]'::jsonb
    )
    FROM _admin_test_stats s
    WHERE s.started OR s.subbed_on
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- After a full month is played: sprinkle 15 yellows + 1 red across the month
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_testing_seed_month_discipline(
  p_season_id bigint,
  p_gpsl_month text,
  p_yellow_target int DEFAULT 15,
  p_red_target int DEFAULT 1
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(btrim(p_gpsl_month));
  v_existing_y int;
  v_existing_r int;
  v_need_y int;
  v_need_r int;
  v_i int;
  v_fix_id bigint;
  v_club text;
  v_player text;
  v_pick record;
  v_touched jsonb := '[]'::jsonb;
  v_yellows_added int := 0;
  v_reds_added int := 0;
  v_pair record;
  v_stats jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_season_id IS NULL OR v_month IS NULL OR v_month = '' THEN
    RAISE EXCEPTION 'season_id and gpsl_month required';
  END IF;

  SELECT
    count(*) FILTER (WHERE m.yellow_card)::int,
    count(*) FILTER (WHERE m.red_card)::int
  INTO v_existing_y, v_existing_r
  FROM public.competition_match_player_stats m
  JOIN public.competition_fixtures f ON f.id = m.fixture_id
  WHERE f.season_id = p_season_id
    AND f.gpsl_month = v_month
    AND f.status = 'played'
    AND f.competition_type IN ('league', 'cup');

  v_need_y := greatest(coalesce(p_yellow_target, 15) - coalesce(v_existing_y, 0), 0);
  v_need_r := greatest(coalesce(p_red_target, 1) - coalesce(v_existing_r, 0), 0);

  IF v_need_y = 0 AND v_need_r = 0 THEN
    RETURN jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'targets already met',
      'yellows_existing', v_existing_y,
      'reds_existing', v_existing_r,
      'yellow_target', p_yellow_target,
      'red_target', p_red_target
    );
  END IF;

  -- Yellows
  FOR v_i IN 1..v_need_y LOOP
    SELECT m.fixture_id, m.club_short_name, m.player_id
    INTO v_fix_id, v_club, v_player
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.season_id = p_season_id
      AND f.gpsl_month = v_month
      AND f.status = 'played'
      AND f.competition_type IN ('league', 'cup')
      AND (
        coalesce(m.appeared, false)
        OR coalesce(m.started, false)
        OR coalesce(m.subbed_on, false)
      )
      AND NOT coalesce(m.yellow_card, false)
      AND NOT coalesce(m.red_card, false)
    ORDER BY random()
    LIMIT 1;

    EXIT WHEN v_fix_id IS NULL;

    UPDATE public.competition_match_player_stats
    SET yellow_card = true
    WHERE fixture_id = v_fix_id
      AND club_short_name = v_club
      AND player_id = v_player;

    v_yellows_added := v_yellows_added + 1;
    v_touched := v_touched || jsonb_build_array(jsonb_build_object(
      'kind', 'yellow',
      'fixture_id', v_fix_id,
      'club_short_name', v_club,
      'player_id', v_player
    ));
  END LOOP;

  -- Reds (one for the whole month by default)
  FOR v_i IN 1..v_need_r LOOP
    SELECT m.fixture_id, m.club_short_name, m.player_id
    INTO v_fix_id, v_club, v_player
    FROM public.competition_match_player_stats m
    JOIN public.competition_fixtures f ON f.id = m.fixture_id
    WHERE f.season_id = p_season_id
      AND f.gpsl_month = v_month
      AND f.status = 'played'
      AND f.competition_type IN ('league', 'cup')
      AND (
        coalesce(m.appeared, false)
        OR coalesce(m.started, false)
        OR coalesce(m.subbed_on, false)
      )
      AND NOT coalesce(m.red_card, false)
    ORDER BY random()
    LIMIT 1;

    EXIT WHEN v_fix_id IS NULL;

    UPDATE public.competition_match_player_stats
    SET red_card = true
    WHERE fixture_id = v_fix_id
      AND club_short_name = v_club
      AND player_id = v_player;

    v_reds_added := v_reds_added + 1;
    v_touched := v_touched || jsonb_build_array(jsonb_build_object(
      'kind', 'red',
      'fixture_id', v_fix_id,
      'club_short_name', v_club,
      'player_id', v_player
    ));
  END LOOP;

  -- Re-run discipline for each touched club/fixture (suspensions / yellow accum)
  FOR v_pair IN
    SELECT DISTINCT
      (elem ->> 'fixture_id')::bigint AS fixture_id,
      elem ->> 'club_short_name' AS club_short_name
    FROM jsonb_array_elements(v_touched) elem
  LOOP
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'player_id', m.player_id,
          'started', coalesce(m.started, false),
          'subbed_on', coalesce(m.subbed_on, false),
          'appeared', coalesce(m.appeared, false),
          'goals', m.goals,
          'assists', m.assists,
          'rating', m.rating,
          'potm', coalesce(m.is_player_of_match, false),
          'yellow_card', coalesce(m.yellow_card, false),
          'red_card', coalesce(m.red_card, false)
        )
      ),
      '[]'::jsonb
    )
    INTO v_stats
    FROM public.competition_match_player_stats m
    WHERE m.fixture_id = v_pair.fixture_id
      AND m.club_short_name = v_pair.club_short_name;

    PERFORM public.competition_process_match_discipline(
      v_pair.fixture_id,
      p_season_id,
      v_pair.club_short_name,
      v_stats
    );
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'skipped', false,
    'gpsl_month', v_month,
    'yellow_target', p_yellow_target,
    'red_target', p_red_target,
    'yellows_existing_before', v_existing_y,
    'reds_existing_before', v_existing_r,
    'yellows_added', v_yellows_added,
    'reds_added', v_reds_added,
    'assignments', v_touched
  );
END;
$function$;

-- Wire into month deploy: seed cards when the month has no scheduled fixtures left
CREATE OR REPLACE FUNCTION public.admin_testing_deploy_month_results(
  p_gpsl_month text,
  p_confirm_phrase text DEFAULT NULL,
  p_limit integer DEFAULT NULL,
  p_after_fixture_id bigint DEFAULT NULL,
  p_include_details boolean DEFAULT false
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
  v_batch_count int := 0;
  v_last_fixture_id bigint;
  v_has_more boolean := false;
  v_remaining int := 0;
  v_scheduled_left int := 0;
  v_discipline jsonb := NULL;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_after_fixture_id IS NULL
     AND coalesce(trim(p_confirm_phrase), '') <> 'DEPLOY TEST MONTH' THEN
    RAISE EXCEPTION 'Confirmation phrase required — type exactly: DEPLOY TEST MONTH';
  END IF;

  PERFORM set_config('statement_timeout', '120s', true);

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
      AND (p_after_fixture_id IS NULL OR f.id > p_after_fixture_id)
    ORDER BY
      CASE f.competition_type WHEN 'league' THEN 0 ELSE 1 END,
      f.cup_code NULLS FIRST,
      f.cup_round NULLS FIRST,
      f.cup_match NULLS FIRST,
      f.matchday,
      f.division,
      f.id
    LIMIT p_limit
  LOOP
    v_batch_count := v_batch_count + 1;
    v_last_fixture_id := v_fixture.id;

    BEGIN
      v_result := public.admin_testing_deploy_scheduled_fixture(v_fixture.id);
      IF coalesce(p_include_details, false) THEN
        v_deployed := v_deployed || jsonb_build_array(v_result);
      END IF;
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

  IF v_last_fixture_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.competition_fixtures f
      WHERE f.season_id = v_season_id
        AND f.gpsl_month = v_month
        AND f.status = 'scheduled'
        AND f.competition_type IN ('league', 'cup')
        AND f.id > v_last_fixture_id
    )
    INTO v_has_more;
  END IF;

  SELECT count(*)::int
  INTO v_remaining
  FROM public.competition_fixtures f
  WHERE f.season_id = v_season_id
    AND f.gpsl_month = v_month
    AND f.status = 'scheduled'
    AND f.competition_type IN ('league', 'cup')
    AND public.admin_testing_fixture_squads_ready(
      f.home_club_short_name,
      f.away_club_short_name,
      f.id
    );

  SELECT count(*)::int
  INTO v_scheduled_left
  FROM public.competition_fixtures f
  WHERE f.season_id = v_season_id
    AND f.gpsl_month = v_month
    AND f.status = 'scheduled'
    AND f.competition_type IN ('league', 'cup');

  -- Full month complete → seed 15 yellows + 1 red across all played fixtures
  IF coalesce(v_scheduled_left, 0) = 0 THEN
    BEGIN
      v_discipline := public.admin_testing_seed_month_discipline(
        v_season_id, v_month, 15, 1
      );
    EXCEPTION
      WHEN OTHERS THEN
        v_discipline := jsonb_build_object(
          'ok', false,
          'error', SQLERRM
        );
    END;
  END IF;

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
    'deployed_count', v_league_deployed + v_cup_deployed,
    'league_deployed_count', v_league_deployed,
    'cup_deployed_count', v_cup_deployed,
    'error_count', jsonb_array_length(v_errors),
    'error_summary', v_error_summary,
    'batch_count', v_batch_count,
    'has_more', coalesce(v_has_more, false),
    'next_after_fixture_id', v_last_fixture_id,
    'remaining_ready', v_remaining,
    'scheduled_left', v_scheduled_left,
    'discipline', v_discipline,
    'deployed', CASE WHEN coalesce(p_include_details, false) THEN v_deployed ELSE NULL END,
    'errors', v_errors
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_testing_build_club_match_stats(text, int, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_testing_seed_month_discipline(bigint, text, int, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_testing_deploy_month_results(text, text, integer, bigint, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
