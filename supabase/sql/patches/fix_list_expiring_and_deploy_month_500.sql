-- =============================================================================
-- Fix HTTP 500 on:
--   • list_expiring_contract_market  (nav Active badge / squad status)
--   • admin_testing_deploy_month_results (admin_test_deploy_month.html)
--
-- Typical causes:
--   1) list_expiring: missing wage helpers, pesdb_unavailable, or bad Age casts
--   2) deploy_month: old 2-arg overload ambiguity, or broken clinch rename wrap
-- Safe re-run.
-- =============================================================================

-- Wage helpers (no-op if already present)
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
  v_cur numeric := greatest(coalesce(p_current_wage, 0), 0);
  v_pct numeric := public.contract_expiry_min_wage_uplift_pct();
  v_min numeric;
BEGIN
  IF v_cur <= 0 THEN
    RETURN 10000::numeric;
  END IF;
  v_min := ceil(v_cur * (1 + (v_pct / 100.0)));
  IF v_min <= v_cur THEN
    v_min := v_cur + 1;
  END IF;
  RETURN v_min;
END;
$function$;

CREATE OR REPLACE FUNCTION public.is_player_expiry_auction_exempt(
  p_player_id text,
  p_club_short_name text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid  text := btrim(p_player_id);
  v_club text := btrim(p_club_short_name);
  v_age  numeric;
  v_hg   boolean;
  v_age_txt text;
BEGIN
  IF v_pid IS NULL OR v_pid = '' OR v_club IS NULL OR v_club = '' THEN
    RETURN false;
  END IF;

  SELECT nullif(btrim(p."Age"::text), '') INTO v_age_txt
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  IF NOT FOUND OR v_age_txt IS NULL THEN
    RETURN false;
  END IF;

  BEGIN
    v_age := v_age_txt::numeric;
  EXCEPTION
    WHEN OTHERS THEN
      RETURN false;
  END;

  BEGIN
    v_hg := public.is_player_homegrown(v_pid, v_club);
  EXCEPTION
    WHEN OTHERS THEN
      v_hg := false;
  END;

  IF v_hg AND v_age <= 23 THEN
    RETURN true;
  END IF;
  IF (NOT v_hg) AND v_age <= 21 THEN
    RETURN true;
  END IF;
  RETURN false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_expiry_auction_applies(p_player_id text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player public."Players"%rowtype;
  v_club text;
  v_unavail boolean := false;
BEGIN
  SELECT * INTO v_player
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  BEGIN
    v_unavail := coalesce(v_player.pesdb_unavailable, false);
  EXCEPTION
    WHEN undefined_column THEN
      v_unavail := false;
  END;

  IF v_unavail THEN
    RETURN false;
  END IF;

  BEGIN
    v_club := public.player_contracted_club_key(v_player."Contracted_Team");
  EXCEPTION
    WHEN OTHERS THEN
      v_club := nullif(btrim(coalesce(v_player."Contracted_Team", '')), '');
  END;

  IF v_club IS NULL THEN
    RETURN false;
  END IF;

  IF coalesce(v_player.contract_seasons_remaining, 0) <> 1 THEN
    RETURN false;
  END IF;

  IF public.is_player_expiry_auction_exempt(btrim(p_player_id), v_club) THEN
    RETURN false;
  END IF;

  RETURN true;
EXCEPTION
  WHEN OTHERS THEN
    RETURN false;
END;
$function$;

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
      AND public.player_expiry_auction_applies(p."Konami_ID"::text)
    ORDER BY p."Name"
  LOOP
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
        WHEN undefined_table THEN
          v_my_bid := NULL;
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
  END LOOP;

  RETURN coalesce(v_out, '[]'::jsonb);
EXCEPTION
  WHEN OTHERS THEN
    -- Never 500 the nav / squad — return empty market
    RETURN '[]'::jsonb;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.list_expiring_contract_market() TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_expiry_auction_applies(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_player_expiry_auction_exempt(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_expiry_wage_bid_step() TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_expiry_min_wage_offer(numeric) TO authenticated;

-- Drop legacy 2-arg deploy overload (causes PostgREST ambiguity / odd 500s)
DROP FUNCTION IF EXISTS public.admin_testing_deploy_month_results(text, text);

-- Repair clinch wrap if rename left a broken state
DO $$
BEGIN
  IF to_regprocedure('public.competition_process_league_clinches_impl(bigint)') IS NOT NULL
     AND to_regprocedure('public.competition_process_league_clinches(bigint)') IS NULL THEN
    ALTER FUNCTION public.competition_process_league_clinches_impl(bigint)
      RENAME TO competition_process_league_clinches;
  END IF;
END $$;

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
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_month = '' THEN
    RAISE EXCEPTION 'gpsl_month required';
  END IF;

  IF p_after_fixture_id IS NULL
     AND coalesce(trim(p_confirm_phrase), '') <> 'DEPLOY TEST MONTH' THEN
    RAISE EXCEPTION 'Confirmation phrase required — type exactly: DEPLOY TEST MONTH';
  END IF;

  PERFORM set_config('statement_timeout', '180s', true);
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
    RAISE EXCEPTION 'No current competition season';
  END IF;

  IF to_regprocedure('public.admin_testing_deploy_scheduled_fixture(bigint)') IS NULL THEN
    RAISE EXCEPTION 'admin_testing_deploy_scheduled_fixture missing — run admin_testing_deploy_fix.sql';
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
  INTO v_scheduled_left
  FROM public.competition_fixtures f
  WHERE f.season_id = v_season_id
    AND f.gpsl_month = v_month
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
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_testing_deploy_month_results(text, text, integer, bigint, boolean)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
