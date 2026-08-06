-- =============================================================================
-- Fix HTTP 500 on:
--   • list_expiring_contract_market  (nav Active badge / squad status)
--   • admin_testing_deploy_month_results (admin_test_deploy_month.html)
--
-- Run this WHOLE file once in Supabase SQL Editor, then:
--   SELECT public.admin_diagnose_month_deploy_rpcs('december');
-- Hard-refresh the admin page and retry Deploy.
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0) Clinch skip wrap (December deploy often 500s without this — each result
--    re-scans clinches and blows the API gateway timeout)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_def text;
BEGIN
  IF to_regprocedure('public.competition_process_league_clinches(bigint)') IS NULL THEN
    RAISE NOTICE 'competition_process_league_clinches missing — skip wrap';
    RETURN;
  END IF;

  SELECT pg_get_functiondef('public.competition_process_league_clinches(bigint)'::regprocedure)
  INTO v_def;

  IF v_def LIKE '%competition_process_league_clinches_impl%' THEN
    RAISE NOTICE 'clinch skip wrap already installed';
    RETURN;
  END IF;

  IF v_def LIKE '%gpsl.skip_clinch_scan%' THEN
    RAISE NOTICE 'clinch already has skip GUC — no wrap needed';
    RETURN;
  END IF;

  IF to_regprocedure('public.competition_process_league_clinches_impl(bigint)') IS NOT NULL THEN
    DROP FUNCTION public.competition_process_league_clinches_impl(bigint);
  END IF;

  ALTER FUNCTION public.competition_process_league_clinches(bigint)
    RENAME TO competition_process_league_clinches_impl;

  EXECUTE $wrap$
    CREATE OR REPLACE FUNCTION public.competition_process_league_clinches(
      p_season_id bigint DEFAULT NULL
    )
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = public
    AS $function$
    BEGIN
      IF current_setting('gpsl.skip_clinch_scan', true) = 'on' THEN
        RETURN jsonb_build_object('ok', true, 'skipped', true, 'reason', 'bulk_deploy');
      END IF;

      RETURN public.competition_process_league_clinches_impl(p_season_id);
    END;
    $function$;
  $wrap$;

  GRANT EXECUTE ON FUNCTION public.competition_process_league_clinches(bigint)
    TO authenticated, service_role;

  RAISE NOTICE 'clinch skip wrap installed';
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'clinch wrap skipped: %', SQLERRM;
END $$;

-- Repair if a previous patch left only _impl (no public wrapper)
DO $$
BEGIN
  IF to_regprocedure('public.competition_process_league_clinches_impl(bigint)') IS NOT NULL
     AND to_regprocedure('public.competition_process_league_clinches(bigint)') IS NULL THEN
    ALTER FUNCTION public.competition_process_league_clinches_impl(bigint)
      RENAME TO competition_process_league_clinches;
    RAISE NOTICE 'restored competition_process_league_clinches from _impl';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 1) Wage helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.contract_expiry_min_wage_uplift_pct()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 10::numeric; $$;

CREATE OR REPLACE FUNCTION public.contract_expiry_wage_bid_step()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 1::numeric; $$;

CREATE OR REPLACE FUNCTION public.contract_expiry_min_wage_offer(p_current_wage numeric)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_wage numeric := greatest(coalesce(p_current_wage, 0), 0);
  v_pct  numeric := 10;
BEGIN
  BEGIN
    v_pct := public.contract_expiry_min_wage_uplift_pct();
  EXCEPTION
    WHEN OTHERS THEN
      v_pct := 10;
  END;
  RETURN greatest(round(v_wage * (1 + v_pct / 100.0), 0), v_wage + 1, 10000);
END;
$function$;

-- Do NOT replace is_player_expiry_auction_exempt — real logic lives in
-- contract_expiry_uncontested_brackets.sql. Only stub if missing.
DO $$
BEGIN
  IF to_regprocedure('public.is_player_expiry_auction_exempt(text, text)') IS NULL THEN
    EXECUTE $stub$
      CREATE FUNCTION public.is_player_expiry_auction_exempt(p_player_id text, p_club text)
      RETURNS boolean
      LANGUAGE sql
      STABLE
      AS $f$ SELECT false $f$;
    $stub$;
    GRANT EXECUTE ON FUNCTION public.is_player_expiry_auction_exempt(text, text) TO authenticated;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.player_expiry_auction_applies(p_player_id text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_seasons int;
  v_unavail boolean := false;
  v_team text;
BEGIN
  SELECT
    p."Contracted_Team",
    coalesce(p.contract_seasons_remaining, 0)
  INTO v_team, v_seasons
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- Safe: column may be missing on older DBs
  BEGIN
    EXECUTE
      'SELECT coalesce(pesdb_unavailable, false)
       FROM public."Players"
       WHERE "Konami_ID"::text = $1'
    INTO v_unavail
    USING btrim(p_player_id);
  EXCEPTION
    WHEN OTHERS THEN
      v_unavail := false;
  END;

  IF v_unavail THEN
    RETURN false;
  END IF;

  IF v_seasons <> 1 THEN
    RETURN false;
  END IF;

  BEGIN
    v_club := public.player_contracted_club_key(v_team);
  EXCEPTION
    WHEN OTHERS THEN
      v_club := nullif(btrim(coalesce(v_team, '')), '');
  END;

  IF v_club IS NULL THEN
    RETURN false;
  END IF;

  BEGIN
    IF public.is_player_expiry_auction_exempt(btrim(p_player_id), v_club) THEN
      RETURN false;
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      NULL;
  END;

  RETURN true;
EXCEPTION
  WHEN OTHERS THEN
    RETURN false;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2) list_expiring — never raise to the client
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_expiring_contract_market()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_viewer text;
  v_season text;
  v_out    jsonb := '[]'::jsonb;
  v_row    record;
  v_my_bid numeric;
  v_step   numeric := 1;
  v_min    numeric;
  v_applies boolean;
BEGIN
  BEGIN
    v_season := coalesce(public.current_gpsl_season_label(), 'unknown');
  EXCEPTION
    WHEN OTHERS THEN
      v_season := 'unknown';
  END;

  BEGIN
    v_step := public.contract_expiry_wage_bid_step();
  EXCEPTION
    WHEN OTHERS THEN
      v_step := 1;
  END;

  BEGIN
    v_viewer := public.my_club_shortname();
  EXCEPTION
    WHEN OTHERS THEN
      v_viewer := NULL;
  END;

  FOR v_row IN
    SELECT
      p."Konami_ID"::text AS player_id,
      p."Name" AS player_name,
      p."Position" AS position,
      p."Nation" AS nation,
      p."Playstyle" AS playstyle,
      p."Rating" AS rating,
      p."Age" AS age,
      p.market_value,
      p."Contracted_Team" AS holding_club,
      p.contract_wage AS current_wage
    FROM public."Players" p
    WHERE coalesce(p.contract_seasons_remaining, 0) = 1
      AND nullif(btrim(coalesce(p."Contracted_Team", '')), '') IS NOT NULL
    ORDER BY p."Name"
  LOOP
    BEGIN
      v_applies := public.player_expiry_auction_applies(v_row.player_id);
    EXCEPTION
      WHEN OTHERS THEN
        v_applies := false;
    END;
    IF NOT coalesce(v_applies, false) THEN
      CONTINUE;
    END IF;

    v_my_bid := NULL;
    IF v_viewer IS NOT NULL THEN
      BEGIN
        SELECT b.wage_offer
        INTO v_my_bid
        FROM public.contract_expiry_wage_bids b
        WHERE b.player_id = v_row.player_id
          AND b.season_label = v_season
          AND b.bidder_club_short_name = v_viewer;
      EXCEPTION
        WHEN OTHERS THEN
          v_my_bid := NULL;
      END;
    END IF;

    BEGIN
      v_min := public.contract_expiry_min_wage_offer(v_row.current_wage);
    EXCEPTION
      WHEN OTHERS THEN
        v_min := greatest(coalesce(v_row.current_wage, 0) + 1, 10000);
    END;

    BEGIN
      v_out := v_out || jsonb_build_array(
        jsonb_build_object(
          'player_id', v_row.player_id,
          'player_name', v_row.player_name,
          'position', v_row.position,
          'nation', v_row.nation,
          'playstyle', v_row.playstyle,
          'rating', v_row.rating,
          'age', v_row.age,
          'market_value', v_row.market_value,
          'holding_club', v_row.holding_club,
          'current_wage', v_row.current_wage,
          'min_wage_offer', v_min,
          'wage_step', v_step,
          'my_wage_bid', v_my_bid,
          'season_label', v_season
        )
      );
    EXCEPTION
      WHEN OTHERS THEN
        NULL; -- skip bad row
    END;
  END LOOP;

  RETURN coalesce(v_out, '[]'::jsonb);
EXCEPTION
  WHEN OTHERS THEN
    RETURN '[]'::jsonb;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.list_expiring_contract_market() TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_expiry_auction_applies(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_expiry_wage_bid_step() TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_expiry_min_wage_offer(numeric) TO authenticated;
DO $$
BEGIN
  IF to_regprocedure('public.is_player_expiry_auction_exempt(text, text)') IS NOT NULL THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.is_player_expiry_auction_exempt(text, text) TO authenticated';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3) Drop ALL deploy_month overloads (kills PostgREST ambiguity 500s)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'admin_testing_deploy_month_results'
  LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig || ' CASCADE';
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 4) Safe deploy_month — returns {ok:false,error:...} instead of HTTP 500
-- ---------------------------------------------------------------------------
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
  v_month text := lower(trim(coalesce(p_gpsl_month, '')));
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
  v_clinches jsonb := NULL;
  v_month_label text;
  v_limit int := greatest(1, least(coalesce(p_limit, 1), 2));
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Admin only');
  END IF;

  IF v_month = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'gpsl_month required');
  END IF;

  IF p_after_fixture_id IS NULL
     AND coalesce(trim(p_confirm_phrase), '') <> 'DEPLOY TEST MONTH' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'Confirmation phrase required — type exactly: DEPLOY TEST MONTH'
    );
  END IF;

  BEGIN
    PERFORM set_config('statement_timeout', '180s', true);
  EXCEPTION
    WHEN OTHERS THEN
      NULL;
  END;

  BEGIN
    PERFORM set_config('gpsl.skip_clinch_scan', 'on', true);
  EXCEPTION
    WHEN OTHERS THEN
      NULL;
  END;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No current competition season');
  END IF;

  IF to_regprocedure('public.admin_testing_deploy_scheduled_fixture(bigint)') IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'admin_testing_deploy_scheduled_fixture missing — run admin_testing_deploy_fix.sql'
    );
  END IF;

  FOR v_fixture IN
    SELECT f.*
    FROM public.competition_fixtures f
    WHERE f.season_id = v_season_id
      AND lower(trim(coalesce(f.gpsl_month, ''))) = v_month
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
    LIMIT v_limit
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

  BEGIN
    PERFORM set_config('gpsl.skip_clinch_scan', 'off', true);
  EXCEPTION
    WHEN OTHERS THEN
      NULL;
  END;

  -- Do NOT run full clinch mid-month here (timeout risk). Admin can scan separately.
  IF v_league_deployed > 0 THEN
    v_clinches := jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'deferred_until_month_complete'
    );
  END IF;

  IF v_last_fixture_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.competition_fixtures f
      WHERE f.season_id = v_season_id
        AND lower(trim(coalesce(f.gpsl_month, ''))) = v_month
        AND f.status = 'scheduled'
        AND f.competition_type IN ('league', 'cup')
        AND f.id > v_last_fixture_id
    )
    INTO v_has_more;
  END IF;

  SELECT count(*)::int
  INTO v_scheduled_left
  FROM public.competition_fixtures f
  WHERE f.season_id = v_season_id
    AND lower(trim(coalesce(f.gpsl_month, ''))) = v_month
    AND f.status = 'scheduled'
    AND f.competition_type IN ('league', 'cup');

  v_remaining := v_scheduled_left;

  IF coalesce(v_scheduled_left, 0) = 0 THEN
    v_clinches := jsonb_build_object(
      'ok', true,
      'skipped', true,
      'reason', 'run_admin_scan_league_clinches'
    );

    IF to_regprocedure('public.admin_testing_seed_month_discipline(bigint,text,int,int)') IS NOT NULL THEN
      BEGIN
        v_discipline := public.admin_testing_seed_month_discipline(
          v_season_id, v_month, 15, 1
        );
      EXCEPTION
        WHEN OTHERS THEN
          v_discipline := jsonb_build_object('ok', false, 'error', SQLERRM);
      END;
    END IF;
  END IF;

  BEGIN
    SELECT coalesce(jsonb_object_agg(err, cnt), '{}'::jsonb)
    INTO v_error_summary
    FROM (
      SELECT elem ->> 'error' AS err, count(*)::int AS cnt
      FROM jsonb_array_elements(v_errors) elem
      GROUP BY 1
    ) s;
  EXCEPTION
    WHEN OTHERS THEN
      v_error_summary := '{}'::jsonb;
  END;

  BEGIN
    v_month_label := public.competition_gpsl_month_label(v_month);
  EXCEPTION
    WHEN OTHERS THEN
      v_month_label := initcap(v_month);
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'gpsl_month', v_month,
    'gpsl_month_label', v_month_label,
    'season_id', v_season_id,
    'deployed_count', v_league_deployed + v_cup_deployed,
    'league_deployed_count', v_league_deployed,
    'cup_deployed_count', v_cup_deployed,
    'error_count', jsonb_array_length(v_errors),
    'error_summary', v_error_summary,
    'batch_count', v_batch_count,
    'batch_limit', v_limit,
    'has_more', coalesce(v_has_more, false),
    'next_after_fixture_id', v_last_fixture_id,
    'remaining_ready', v_remaining,
    'scheduled_left', v_scheduled_left,
    'discipline', v_discipline,
    'clinches', v_clinches,
    'deployed', CASE WHEN coalesce(p_include_details, false) THEN v_deployed ELSE NULL END,
    'errors', v_errors
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', SQLERRM,
      'sqlstate', SQLSTATE
    );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_testing_deploy_month_results(text, text, integer, bigint, boolean)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 5) Diagnostic — run after applying this file
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_diagnose_month_deploy_rpcs(
  p_gpsl_month text DEFAULT 'december'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text := lower(trim(coalesce(p_gpsl_month, 'december')));
  v_out jsonb := '{}'::jsonb;
  v_tmp jsonb;
  v_season_id bigint;
  v_n int;
  v_overloads text[];
  v_clinch_def text;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Admin only');
  END IF;

  SELECT array_agg(p.oid::regprocedure::text ORDER BY p.oid)
  INTO v_overloads
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'admin_testing_deploy_month_results';

  v_out := v_out || jsonb_build_object(
    'deploy_month_overloads', coalesce(to_jsonb(v_overloads), '[]'::jsonb),
    'deploy_scheduled_fixture',
      to_regprocedure('public.admin_testing_deploy_scheduled_fixture(bigint)') IS NOT NULL,
    'list_expiring_exists',
      to_regprocedure('public.list_expiring_contract_market()') IS NOT NULL,
    'clinch_exists',
      to_regprocedure('public.competition_process_league_clinches(bigint)') IS NOT NULL,
    'clinch_impl_exists',
      to_regprocedure('public.competition_process_league_clinches_impl(bigint)') IS NOT NULL
  );

  IF to_regprocedure('public.competition_process_league_clinches(bigint)') IS NOT NULL THEN
    SELECT pg_get_functiondef('public.competition_process_league_clinches(bigint)'::regprocedure)
    INTO v_clinch_def;
    v_out := v_out || jsonb_build_object(
      'clinch_has_skip_guc',
      coalesce(v_clinch_def LIKE '%gpsl.skip_clinch_scan%'
               OR v_clinch_def LIKE '%competition_process_league_clinches_impl%', false)
    );
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  SELECT count(*)::int INTO v_n
  FROM public.competition_fixtures f
  WHERE f.season_id = v_season_id
    AND lower(trim(coalesce(f.gpsl_month, ''))) = v_month
    AND f.status = 'scheduled'
    AND f.competition_type IN ('league', 'cup');

  v_out := v_out || jsonb_build_object(
    'season_id', v_season_id,
    'month', v_month,
    'scheduled_league_cup', v_n
  );

  BEGIN
    v_tmp := public.list_expiring_contract_market();
    v_out := v_out || jsonb_build_object(
      'list_expiring_ok', true,
      'list_expiring_count', coalesce(jsonb_array_length(v_tmp), 0)
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'list_expiring_ok', false,
        'list_expiring_error', SQLERRM
      );
  END;

  BEGIN
    PERFORM set_config('gpsl.skip_clinch_scan', 'on', true);
    v_out := v_out || jsonb_build_object('skip_clinch_guc_ok', true);
  EXCEPTION
    WHEN OTHERS THEN
      v_out := v_out || jsonb_build_object(
        'skip_clinch_guc_ok', false,
        'skip_clinch_guc_error', SQLERRM
      );
  END;

  RETURN v_out || jsonb_build_object('ok', true);
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM, 'partial', v_out);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_diagnose_month_deploy_rpcs(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
