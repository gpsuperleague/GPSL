-- =============================================================================
-- Admin testing tools — manager assign + deploy month results (sandbox only)
-- Run once in Supabase SQL Editor. Safe to re-run (CREATE OR REPLACE).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Build random squad stats matching a team score (11 starters, 0–5 subs, POTM)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_testing_build_club_match_stats(
  p_club text,
  p_expected_goals int
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

  SELECT array_agg(p."Konami_ID"::text ORDER BY random())
  INTO v_players
  FROM public."Players" p
  WHERE p."Contracted_Team" = p_club;

  v_n := coalesce(array_length(v_players, 1), 0);
  IF v_n < 11 THEN
    RAISE EXCEPTION 'Club % has only % contracted players (need 11)', p_club, v_n;
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

  UPDATE _admin_test_stats SET potm = (player_id = v_potm_player);

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
          'potm', s.potm
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
-- Deploy one scheduled fixture with scores + both squads' stats (no inbox flow)
-- ---------------------------------------------------------------------------

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

  IF v_fixture.status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture % is not scheduled (status=%)', p_fixture_id, v_fixture.status;
  END IF;

  IF v_fixture.competition_type = 'cup' THEN
    RAISE EXCEPTION 'Cup fixtures are not supported by month deploy (use matchday for ET/pen)';
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
      status = 'played'
  WHERE id = p_fixture_id;

  PERFORM public.competition_apply_club_player_stats(
    v_fixture.id,
    v_fixture.season_id,
    v_fixture.home_club_short_name,
    v_home_stats,
    p_home_goals::int
  );
  PERFORM public.competition_apply_club_player_stats(
    v_fixture.id,
    v_fixture.season_id,
    v_fixture.away_club_short_name,
    v_away_stats,
    p_away_goals::int
  );

  PERFORM public.competition_settle_fixture_gates(p_fixture_id);

  IF v_fixture.competition_type = 'league' THEN
    PERFORM public.competition_try_pay_league_division_prizes(
      v_fixture.season_id,
      v_fixture.division
    );
  ELSIF v_fixture.competition_type = 'cup' THEN
    PERFORM public.competition_cup_on_fixture_played(p_fixture_id);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'home_club', v_fixture.home_club_short_name,
    'away_club', v_fixture.away_club_short_name,
    'score', format('%s-%s', p_home_goals, p_away_goals),
    'matchday', v_fixture.matchday,
    'gpsl_month', v_fixture.gpsl_month
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Preview fixtures for a GPSL month (current season, league, scheduled)
-- ---------------------------------------------------------------------------

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
  v_ready int := 0;
  v_blocked int := 0;
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

  SELECT coalesce(jsonb_agg(row_to_json(t)::jsonb ORDER BY t.matchday, t.division, t.id), '[]'::jsonb)
  INTO v_fixtures
  FROM (
    SELECT
      f.id,
      f.matchday,
      f.division,
      f.gpsl_month,
      f.week_in_month,
      f.home_club_short_name AS home_club,
      f.away_club_short_name AS away_club,
      f.status,
      f.competition_type,
      (
        SELECT count(*)::int
        FROM public."Players" p
        WHERE p."Contracted_Team" = f.home_club_short_name
      ) AS home_squad_size,
      (
        SELECT count(*)::int
        FROM public."Players" p
        WHERE p."Contracted_Team" = f.away_club_short_name
      ) AS away_squad_size,
      (
        f.status = 'scheduled'
        AND f.competition_type = 'league'
        AND (
          SELECT count(*) FROM public."Players" p
          WHERE p."Contracted_Team" = f.home_club_short_name
        ) >= 11
        AND (
          SELECT count(*) FROM public."Players" p
          WHERE p."Contracted_Team" = f.away_club_short_name
        ) >= 11
      ) AS ready
    FROM public.competition_fixtures f
    WHERE f.season_id = v_season_id
      AND f.gpsl_month = v_month
    ORDER BY f.matchday, f.division, f.id
  ) t;

  SELECT
    count(*) FILTER (WHERE (elem ->> 'ready')::boolean),
    count(*) FILTER (WHERE NOT coalesce((elem ->> 'ready')::boolean, false))
  INTO v_ready, v_blocked
  FROM jsonb_array_elements(v_fixtures) elem;

  RETURN jsonb_build_object(
    'gpsl_month', v_month,
    'gpsl_month_label', public.competition_gpsl_month_label(v_month),
    'season_id', v_season_id,
    'fixtures', v_fixtures,
    'scheduled_league_ready', v_ready,
    'blocked_or_other', v_blocked,
    'confirm_phrase', 'DEPLOY TEST MONTH'
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Deploy all ready league fixtures for a GPSL month
-- ---------------------------------------------------------------------------

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
  v_home_goals smallint;
  v_away_goals smallint;
  v_deployed jsonb := '[]'::jsonb;
  v_errors jsonb := '[]'::jsonb;
  v_result jsonb;
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
      AND f.competition_type = 'league'
    ORDER BY f.matchday, f.division, f.id
  LOOP
    BEGIN
      IF (
        SELECT count(*) FROM public."Players" p
        WHERE p."Contracted_Team" = v_fixture.home_club_short_name
      ) < 11
      OR (
        SELECT count(*) FROM public."Players" p
        WHERE p."Contracted_Team" = v_fixture.away_club_short_name
      ) < 11 THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'fixture_id', v_fixture.id,
          'error', 'Club squad smaller than 11 players'
        ));
        CONTINUE;
      END IF;

      v_home_goals := floor(random() * 5)::smallint;
      v_away_goals := floor(random() * 5)::smallint;

      v_result := public.admin_testing_deploy_fixture_result(
        v_fixture.id,
        v_home_goals,
        v_away_goals
      );
      v_deployed := v_deployed || jsonb_build_array(v_result);
    EXCEPTION
      WHEN OTHERS THEN
        v_errors := v_errors || jsonb_build_array(jsonb_build_object(
          'fixture_id', v_fixture.id,
          'error', SQLERRM
        ));
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'gpsl_month', v_month,
    'gpsl_month_label', public.competition_gpsl_month_label(v_month),
    'season_id', v_season_id,
    'deployed_count', jsonb_array_length(v_deployed),
    'error_count', jsonb_array_length(v_errors),
    'deployed', v_deployed,
    'errors', v_errors
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Manually assign a manager to a club (testing — waives fee by default)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_testing_assign_manager(
  p_manager_id bigint,
  p_club_short text,
  p_seasons smallint DEFAULT 2,
  p_release_club_manager boolean DEFAULT true,
  p_release_manager_contract boolean DEFAULT false,
  p_waive_fee boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := trim(p_club_short);
  v_mgr public."Managers"%rowtype;
  v_club_mgr_id bigint;
  v_result jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club is required';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_club) THEN
    RAISE EXCEPTION 'Club not found: %', v_club;
  END IF;

  SELECT * INTO v_mgr FROM public."Managers" WHERE id = p_manager_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Manager not found';
  END IF;

  IF v_mgr.contracted_club = v_club THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already_assigned', true,
      'manager_id', p_manager_id,
      'manager_name', v_mgr.name,
      'club', v_club
    );
  END IF;

  SELECT m.id INTO v_club_mgr_id
  FROM public."Managers" m
  WHERE m.contracted_club = v_club
  LIMIT 1;

  IF v_club_mgr_id IS NOT NULL AND v_club_mgr_id <> p_manager_id THEN
    IF NOT coalesce(p_release_club_manager, false) THEN
      RAISE EXCEPTION 'Club % already has manager % — enable release current club manager', v_club, v_club_mgr_id;
    END IF;
    PERFORM public.manager_release_from_club(v_club_mgr_id, NULL, 0, 'admin_testing');
  END IF;

  IF v_mgr.contracted_club IS NOT NULL
     AND btrim(v_mgr.contracted_club) <> ''
     AND v_mgr.contracted_club <> v_club THEN
    IF NOT coalesce(p_release_manager_contract, false) THEN
      RAISE EXCEPTION 'Manager is contracted to % — enable release from current club', v_mgr.contracted_club;
    END IF;
    PERFORM public.manager_release_from_club(p_manager_id, NULL, 0, 'admin_testing');
  END IF;

  v_result := public.manager_assign_to_club(
    p_manager_id,
    v_club,
    greatest(coalesce(p_seasons, 2), 1),
    CASE WHEN coalesce(p_waive_fee, true) THEN 0 ELSE NULL END,
    NOT coalesce(p_waive_fee, true)
  );

  RETURN v_result || jsonb_build_object(
    'manager_name', v_mgr.name,
    'club', v_club
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

GRANT EXECUTE ON FUNCTION public.admin_testing_deploy_month_preview(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_testing_deploy_month_results(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_testing_assign_manager(
  bigint, text, smallint, boolean, boolean, boolean
) TO authenticated;
