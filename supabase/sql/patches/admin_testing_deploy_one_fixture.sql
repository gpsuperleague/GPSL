-- =============================================================================
-- Admin testing: deploy a single fixture result (month → club → fixture)
-- Requires: admin_testing_deploy_skip_unavailable.sql (or later deploy patches)
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_testing_list_month_clubs(
  p_gpsl_month text,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(nullif(btrim(coalesce(p_gpsl_month, '')), ''));
  v_season_id bigint;
  v_rows jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_month IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'month_required');
  END IF;

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  SELECT coalesce(jsonb_agg(x ORDER BY x->>'club_name'), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT DISTINCT ON (ccs.club_short_name)
      jsonb_build_object(
        'club_short_name', ccs.club_short_name,
        'club_name', coalesce(c."Club", ccs.club_short_name),
        'division', ccs.division,
        'fixture_count', (
          SELECT count(*)::int
          FROM public.competition_fixtures f
          WHERE f.season_id = v_season_id
            AND lower(f.gpsl_month) = v_month
            AND f.competition_type IN ('league', 'cup')
            AND (
              f.home_club_short_name = ccs.club_short_name
              OR f.away_club_short_name = ccs.club_short_name
            )
        ),
        'scheduled_count', (
          SELECT count(*)::int
          FROM public.competition_fixtures f
          WHERE f.season_id = v_season_id
            AND lower(f.gpsl_month) = v_month
            AND f.status = 'scheduled'
            AND f.competition_type IN ('league', 'cup')
            AND (
              f.home_club_short_name = ccs.club_short_name
              OR f.away_club_short_name = ccs.club_short_name
            )
        )
      ) AS x
    FROM public.competition_club_seasons ccs
    LEFT JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
    WHERE ccs.season_id = v_season_id
      AND EXISTS (
        SELECT 1
        FROM public.competition_fixtures f
        WHERE f.season_id = v_season_id
          AND lower(f.gpsl_month) = v_month
          AND f.competition_type IN ('league', 'cup')
          AND (
            f.home_club_short_name = ccs.club_short_name
            OR f.away_club_short_name = ccs.club_short_name
          )
      )
    ORDER BY ccs.club_short_name
  ) q;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'gpsl_month', v_month,
    'clubs', coalesce(v_rows, '[]'::jsonb)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_testing_list_club_month_fixtures(
  p_gpsl_month text,
  p_club_short_name text,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(nullif(btrim(coalesce(p_gpsl_month, '')), ''));
  v_club text := btrim(coalesce(p_club_short_name, ''));
  v_season_id bigint;
  v_rows jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_month IS NULL OR v_club = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'month_and_club_required');
  END IF;

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  SELECT coalesce(jsonb_agg(row_data ORDER BY sort_key, fixture_id), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT
      f.id AS fixture_id,
      CASE f.competition_type WHEN 'league' THEN 0 ELSE 1 END AS sort_key,
      jsonb_build_object(
        'fixture_id', f.id,
        'competition_type', f.competition_type,
        'division', f.division,
        'cup_code', f.cup_code,
        'cup_round', f.cup_round,
        'matchday', f.matchday,
        'gpsl_month', f.gpsl_month,
        'status', f.status,
        'home_club_short_name', f.home_club_short_name,
        'away_club_short_name', f.away_club_short_name,
        'home_club_name', coalesce(ch."Club", f.home_club_short_name),
        'away_club_name', coalesce(ca."Club", f.away_club_short_name),
        'home_goals', f.home_goals,
        'away_goals', f.away_goals,
        'is_home', f.home_club_short_name = v_club,
        'opponent_short_name', CASE
          WHEN f.home_club_short_name = v_club THEN f.away_club_short_name
          ELSE f.home_club_short_name
        END,
        'opponent_name', CASE
          WHEN f.home_club_short_name = v_club THEN coalesce(ca."Club", f.away_club_short_name)
          ELSE coalesce(ch."Club", f.home_club_short_name)
        END,
        'competition_label', CASE
          WHEN f.competition_type = 'cup' THEN coalesce(f.cup_code, 'cup')
          WHEN f.division = 'superleague' THEN 'SuperLeague'
          WHEN f.division = 'championship_a' THEN 'Championship A'
          WHEN f.division = 'championship_b' THEN 'Championship B'
          ELSE coalesce(f.division, 'league')
        END,
        'squads_ready', public.admin_testing_fixture_squads_ready(
          f.home_club_short_name,
          f.away_club_short_name,
          f.id
        ),
        'home_available', public.admin_testing_club_available_count(f.home_club_short_name, f.id),
        'away_available', public.admin_testing_club_available_count(f.away_club_short_name, f.id)
      ) AS row_data
    FROM public.competition_fixtures f
    LEFT JOIN public."Clubs" ch ON ch."ShortName" = f.home_club_short_name
    LEFT JOIN public."Clubs" ca ON ca."ShortName" = f.away_club_short_name
    WHERE f.season_id = v_season_id
      AND lower(f.gpsl_month) = v_month
      AND f.competition_type IN ('league', 'cup')
      AND (
        f.home_club_short_name = v_club
        OR f.away_club_short_name = v_club
      )
  ) q;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'gpsl_month', v_month,
    'club_short_name', v_club,
    'fixtures', coalesce(v_rows, '[]'::jsonb)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_testing_deploy_one_fixture(
  p_fixture_id bigint,
  p_confirm_phrase text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_result jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF coalesce(btrim(p_confirm_phrase), '') <> 'DEPLOY TEST FIXTURE' THEN
    RAISE EXCEPTION 'Confirmation phrase required — type exactly: DEPLOY TEST FIXTURE';
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'fixture_not_found');
  END IF;

  IF v_fixture.status <> 'scheduled' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'not_scheduled',
      'status', v_fixture.status,
      'home_goals', v_fixture.home_goals,
      'away_goals', v_fixture.away_goals
    );
  END IF;

  PERFORM set_config('statement_timeout', '60s', true);

  v_result := public.admin_testing_deploy_scheduled_fixture(p_fixture_id);

  RETURN jsonb_build_object(
    'ok', true,
    'fixture_id', p_fixture_id,
    'gpsl_month', v_fixture.gpsl_month,
    'competition_type', v_fixture.competition_type,
    'result', v_result
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_testing_list_month_clubs(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_testing_list_club_month_fixtures(text, text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_testing_deploy_one_fixture(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
