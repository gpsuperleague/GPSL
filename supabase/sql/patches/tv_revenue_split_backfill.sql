-- =============================================================================
-- TV revenue 80/20 split — backfill corrections for legacy full-payout rows.
-- Run after tv_revenue_home_away_split.sql
--
-- SQL Editor (preview):
--   SELECT public.competition_admin_backfill_tv_revenue_split(NULL::bigint, true);
-- Apply:
--   SELECT public.competition_admin_backfill_tv_revenue_split(NULL::bigint, false);
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_tv_resolve_fixture_pool(p_fixture_id bigint)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT coalesce(
    (
      SELECT (l.metadata->>'tv_match_pool')::numeric
      FROM public.competition_finance_ledger l
      WHERE l.fixture_id = p_fixture_id
        AND l.entry_type = 'tv_revenue'
        AND l.metadata ? 'tv_match_pool'
        AND (l.metadata->>'tv_match_pool')::numeric > 0
      LIMIT 1
    ),
    (
      SELECT l.amount
      FROM public.competition_finance_ledger l
      JOIN public.competition_fixtures f ON f.id = p_fixture_id
      WHERE l.fixture_id = p_fixture_id
        AND l.entry_type = 'tv_revenue'
        AND l.club_short_name = f.home_club_short_name
        AND l.amount > 0
        AND NOT (l.metadata ? 'tv_share_pct')
      LIMIT 1
    ),
    (
      SELECT l.amount
      FROM public.competition_finance_ledger l
      JOIN public.competition_fixtures f ON f.id = p_fixture_id
      WHERE l.fixture_id = p_fixture_id
        AND l.entry_type = 'tv_revenue'
        AND l.club_short_name = f.away_club_short_name
        AND l.amount > 0
        AND NOT (l.metadata ? 'tv_share_pct')
      LIMIT 1
    ),
    (SELECT tv_per_match_amount FROM public.global_settings WHERE id = 1)
  );
$$;

CREATE OR REPLACE FUNCTION public.competition_tv_post_share_correction(
  p_fixture public.competition_fixtures,
  p_club_short_name text,
  p_is_home boolean,
  p_pool numeric,
  p_delta numeric,
  p_prior_total numeric,
  p_target_share numeric,
  p_dry_run boolean DEFAULT false
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_desc text;
  v_meta jsonb;
  v_ledger_id bigint;
  v_role text := CASE WHEN p_is_home THEN 'home' ELSE 'away' END;
  v_pct int := CASE WHEN p_is_home THEN 80 ELSE 20 END;
BEGIN
  IF p_delta IS NULL OR abs(p_delta) < 0.005 THEN
    RETURN NULL;
  END IF;

  IF p_dry_run THEN
    RETURN NULL;
  END IF;

  v_desc := format(
    'TV revenue split correction (%s %s%%) MD%s — %s vs %s',
    v_role,
    v_pct,
    p_fixture.matchday,
    p_fixture.home_club_short_name,
    p_fixture.away_club_short_name
  );
  v_meta := jsonb_build_object(
    'gpsl_month', p_fixture.gpsl_month,
    'role', v_role,
    'tv_share_pct', v_pct,
    'tv_match_pool', p_pool,
    'tv_split_backfill', true,
    'correction_delta', p_delta,
    'prior_total', p_prior_total,
    'target_share', p_target_share
  );

  IF to_regprocedure('public.post_club_ledger(text,text,numeric,text,jsonb,bigint,bigint,boolean,boolean)') IS NOT NULL THEN
    RETURN public.post_club_ledger(
      p_club_short_name,
      'tv_revenue',
      p_delta,
      v_desc,
      v_meta,
      p_fixture.season_id,
      p_fixture.id,
      true,
      true
    );
  END IF;

  PERFORM public.competition_credit_club_balance(p_club_short_name, p_delta);
  INSERT INTO public.competition_finance_ledger (
    season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
  )
  VALUES (
    p_fixture.season_id,
    p_fixture.id,
    p_club_short_name,
    'tv_revenue',
    p_delta,
    v_desc,
    v_meta
  )
  RETURNING id INTO v_ledger_id;

  RETURN v_ledger_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_backfill_tv_revenue_split(
  p_season_id bigint DEFAULT NULL,
  p_dry_run boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_fixture public.competition_fixtures;
  v_pool numeric;
  v_home_expected numeric;
  v_away_expected numeric;
  v_home_paid numeric;
  v_away_paid numeric;
  v_home_delta numeric;
  v_away_delta numeric;
  v_fixtures_scanned int := 0;
  v_fixtures_adjusted int := 0;
  v_corrections_posted int := 0;
  v_home_debited numeric := 0;
  v_away_debited numeric := 0;
  v_home_credited numeric := 0;
  v_away_credited numeric := 0;
  v_preview jsonb := '[]'::jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_season_id := coalesce(
    p_season_id,
    (SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1)
  );

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_season');
  END IF;

  FOR v_fixture IN
    SELECT f.*
    FROM public.competition_tv_fixture_selection s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE f.season_id = v_season_id
      AND f.status = 'played'
    ORDER BY f.gpsl_month, f.matchday, f.id
  LOOP
    v_fixtures_scanned := v_fixtures_scanned + 1;

    v_pool := public.competition_tv_resolve_fixture_pool(v_fixture.id);
    IF v_pool IS NULL OR v_pool <= 0 THEN
      CONTINUE;
    END IF;

    v_home_expected := public.competition_tv_home_share(v_pool);
    v_away_expected := public.competition_tv_away_share(v_pool);

    SELECT coalesce(sum(l.amount), 0)
    INTO v_home_paid
    FROM public.competition_finance_ledger l
    WHERE l.fixture_id = v_fixture.id
      AND l.club_short_name = v_fixture.home_club_short_name
      AND l.entry_type = 'tv_revenue';

    SELECT coalesce(sum(l.amount), 0)
    INTO v_away_paid
    FROM public.competition_finance_ledger l
    WHERE l.fixture_id = v_fixture.id
      AND l.club_short_name = v_fixture.away_club_short_name
      AND l.entry_type = 'tv_revenue';

    v_home_delta := v_home_expected - v_home_paid;
    v_away_delta := v_away_expected - v_away_paid;

    IF abs(v_home_delta) < 0.005 AND abs(v_away_delta) < 0.005 THEN
      CONTINUE;
    END IF;

    v_fixtures_adjusted := v_fixtures_adjusted + 1;

    IF p_dry_run THEN
      v_preview := v_preview || jsonb_build_array(
        jsonb_build_object(
          'fixture_id', v_fixture.id,
          'matchday', v_fixture.matchday,
          'fixture', v_fixture.home_club_short_name || ' vs ' || v_fixture.away_club_short_name,
          'pool', v_pool,
          'home_paid', v_home_paid,
          'home_target', v_home_expected,
          'home_delta', v_home_delta,
          'away_paid', v_away_paid,
          'away_target', v_away_expected,
          'away_delta', v_away_delta
        )
      );
      CONTINUE;
    END IF;

    IF abs(v_home_delta) >= 0.005 THEN
      PERFORM public.competition_tv_post_share_correction(
        v_fixture,
        v_fixture.home_club_short_name,
        true,
        v_pool,
        v_home_delta,
        v_home_paid,
        v_home_expected,
        false
      );
      v_corrections_posted := v_corrections_posted + 1;
      IF v_home_delta > 0 THEN
        v_home_credited := v_home_credited + v_home_delta;
      ELSE
        v_home_debited := v_home_debited + abs(v_home_delta);
      END IF;
    END IF;

    IF abs(v_away_delta) >= 0.005 THEN
      PERFORM public.competition_tv_post_share_correction(
        v_fixture,
        v_fixture.away_club_short_name,
        false,
        v_pool,
        v_away_delta,
        v_away_paid,
        v_away_expected,
        false
      );
      v_corrections_posted := v_corrections_posted + 1;
      IF v_away_delta > 0 THEN
        v_away_credited := v_away_credited + v_away_delta;
      ELSE
        v_away_debited := v_away_debited + abs(v_away_delta);
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'season_id', v_season_id,
    'fixtures_scanned', v_fixtures_scanned,
    'fixtures_adjusted', v_fixtures_adjusted,
    'corrections_posted', v_corrections_posted,
    'home_credited', v_home_credited,
    'home_debited', v_home_debited,
    'away_credited', v_away_credited,
    'away_debited', v_away_debited,
    'preview', v_preview
  );
END;
$function$;

DROP FUNCTION IF EXISTS public.competition_admin_backfill_tv_revenue(bigint);

CREATE OR REPLACE FUNCTION public.competition_admin_backfill_tv_revenue(p_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_fixture_id bigint;
  v_split jsonb;
  v_settled int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_season_id := coalesce(
    p_season_id,
    (SELECT id FROM public.competition_seasons WHERE is_current = true ORDER BY id DESC LIMIT 1)
  );

  v_split := public.competition_admin_backfill_tv_revenue_split(v_season_id, false);

  FOR v_fixture_id IN
    SELECT s.fixture_id
    FROM public.competition_tv_fixture_selection s
    JOIN public.competition_fixtures f ON f.id = s.fixture_id
    WHERE f.season_id = v_season_id
      AND f.status = 'played'
  LOOP
    PERFORM public.competition_tv_settle_fixture(v_fixture_id);
    v_settled := v_settled + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'split', v_split,
    'fixtures_settled', v_settled
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_tv_resolve_fixture_pool(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_backfill_tv_revenue_split(bigint, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_backfill_tv_revenue(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
