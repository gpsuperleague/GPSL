-- =============================================================================
-- TV revenue: 80% home / 20% away of tv_per_match_amount (single match pool).
-- Run after competition_tv_revenue.sql and central_bank_model_a_flows.sql
--
-- Backfill preview (SQL Editor):
--   SELECT public.competition_admin_backfill_tv_revenue_split(NULL::bigint, true);
-- Backfill apply:
--   SELECT public.competition_admin_backfill_tv_revenue_split(NULL::bigint, false);
-- =============================================================================
CREATE OR REPLACE FUNCTION public.competition_tv_home_share(p_pool numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT round(coalesce(p_pool, 0) * 0.8, 2);
$$;

CREATE OR REPLACE FUNCTION public.competition_tv_away_share(p_pool numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(p_pool, 0) - public.competition_tv_home_share(p_pool);
$$;

CREATE OR REPLACE FUNCTION public.competition_tv_club_share(
  p_pool numeric,
  p_is_home boolean
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN coalesce(p_is_home, false) THEN public.competition_tv_home_share(p_pool)
    ELSE public.competition_tv_away_share(p_pool)
  END;
$$;

CREATE OR REPLACE FUNCTION public.competition_tv_settle_fixture(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_pool numeric;
  v_home_amount numeric;
  v_away_amount numeric;
  v_desc text;
  v_meta jsonb;
BEGIN
  IF p_fixture_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_tv_fixture_selection WHERE fixture_id = p_fixture_id
  ) THEN
    RETURN;
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
    AND competition_type = 'league'
    AND status = 'played'
    AND home_goals IS NOT NULL
    AND away_goals IS NOT NULL;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_pool := (SELECT tv_per_match_amount FROM public.global_settings WHERE id = 1);

  IF v_pool IS NULL OR v_pool <= 0 THEN
    RETURN;
  END IF;

  v_home_amount := public.competition_tv_home_share(v_pool);
  v_away_amount := public.competition_tv_away_share(v_pool);

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_finance_ledger
    WHERE fixture_id = p_fixture_id
      AND club_short_name = v_fixture.home_club_short_name
      AND entry_type = 'tv_revenue'
  ) THEN
    v_desc := format(
      'TV revenue (home 80%%) MD%s — %s vs %s',
      v_fixture.matchday,
      v_fixture.home_club_short_name,
      v_fixture.away_club_short_name
    );
    v_meta := jsonb_build_object(
      'gpsl_month', v_fixture.gpsl_month,
      'role', 'home',
      'tv_share_pct', 80,
      'tv_match_pool', v_pool
    );
    IF to_regprocedure('public.post_club_ledger(text,text,numeric,text,jsonb,bigint,bigint,boolean,boolean)') IS NOT NULL THEN
      PERFORM public.post_club_ledger(
        v_fixture.home_club_short_name,
        'tv_revenue',
        v_home_amount,
        v_desc,
        v_meta,
        v_fixture.season_id,
        p_fixture_id,
        true,
        true
      );
    ELSE
      PERFORM public.competition_credit_club_balance(v_fixture.home_club_short_name, v_home_amount);
      INSERT INTO public.competition_finance_ledger (
        season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
      )
      VALUES (
        v_fixture.season_id,
        p_fixture_id,
        v_fixture.home_club_short_name,
        'tv_revenue',
        v_home_amount,
        v_desc,
        v_meta
      );
    END IF;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_finance_ledger
    WHERE fixture_id = p_fixture_id
      AND club_short_name = v_fixture.away_club_short_name
      AND entry_type = 'tv_revenue'
  ) THEN
    v_desc := format(
      'TV revenue (away 20%%) MD%s — %s vs %s',
      v_fixture.matchday,
      v_fixture.home_club_short_name,
      v_fixture.away_club_short_name
    );
    v_meta := jsonb_build_object(
      'gpsl_month', v_fixture.gpsl_month,
      'role', 'away',
      'tv_share_pct', 20,
      'tv_match_pool', v_pool
    );
    IF to_regprocedure('public.post_club_ledger(text,text,numeric,text,jsonb,bigint,bigint,boolean,boolean)') IS NOT NULL THEN
      PERFORM public.post_club_ledger(
        v_fixture.away_club_short_name,
        'tv_revenue',
        v_away_amount,
        v_desc,
        v_meta,
        v_fixture.season_id,
        p_fixture_id,
        true,
        true
      );
    ELSE
      PERFORM public.competition_credit_club_balance(v_fixture.away_club_short_name, v_away_amount);
      INSERT INTO public.competition_finance_ledger (
        season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
      )
      VALUES (
        v_fixture.season_id,
        p_fixture_id,
        v_fixture.away_club_short_name,
        'tv_revenue',
        v_away_amount,
        v_desc,
        v_meta
      );
    END IF;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_tv_club_preview(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_me text := public.my_club_shortname();
  v_season_id bigint;
  v_division text;
  v_s public.global_settings;
  v_selected int;
  v_pending int;
  v_pending_amount numeric;
  v_paid_amount numeric;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  IF NOT public.is_gpsl_admin() AND (v_me IS NULL OR v_me <> v_club) THEN
    RAISE EXCEPTION 'Not allowed to preview TV revenue for this club';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  SELECT ccs.division INTO v_division
  FROM public.competition_club_seasons ccs
  WHERE ccs.season_id = v_season_id
    AND ccs.club_short_name = v_club;

  v_s := public.tv_revenue_settings();

  SELECT count(*)::int INTO v_selected
  FROM public.competition_tv_fixture_selection s
  JOIN public.competition_fixtures f ON f.id = s.fixture_id
  WHERE f.season_id = v_season_id
    AND (f.home_club_short_name = v_club OR f.away_club_short_name = v_club);

  SELECT count(*)::int, coalesce(sum(
    public.competition_tv_club_share(
      v_s.tv_per_match_amount,
      f.home_club_short_name = v_club
    )
  ), 0)
  INTO v_pending, v_pending_amount
  FROM public.competition_tv_fixture_selection s
  JOIN public.competition_fixtures f ON f.id = s.fixture_id
  WHERE f.season_id = v_season_id
    AND f.status = 'scheduled'
    AND (f.home_club_short_name = v_club OR f.away_club_short_name = v_club);

  SELECT coalesce(sum(l.amount), 0) INTO v_paid_amount
  FROM public.competition_finance_ledger l
  WHERE l.season_id = v_season_id
    AND l.club_short_name = v_club
    AND l.entry_type = 'tv_revenue';

  RETURN jsonb_build_object(
    'season_id', v_season_id,
    'division', v_division,
    'selected_count', v_selected,
    'pending_count', v_pending,
    'pending_amount', v_pending_amount,
    'paid_amount', v_paid_amount,
    'per_match_amount', v_s.tv_per_match_amount,
    'home_share_pct', 80,
    'away_share_pct', 20,
    'club_min', v_s.tv_club_min_season,
    'club_max', v_s.tv_club_max_season
  );
END;
$function$;

DROP VIEW IF EXISTS public.competition_tv_fixtures_public;

CREATE VIEW public.competition_tv_fixtures_public
WITH (security_invoker = false)
AS
SELECT
  s.season_id,
  s.fixture_id,
  s.division,
  s.gpsl_month,
  public.competition_gpsl_month_label(s.gpsl_month) AS gpsl_month_label,
  s.tv_score,
  s.reasons,
  s.selected_at,
  f.matchday,
  f.home_club_short_name,
  f.away_club_short_name,
  f.status,
  f.home_goals,
  f.away_goals,
  gs.tv_per_match_amount AS tv_match_pool,
  public.competition_tv_home_share(gs.tv_per_match_amount) AS home_tv_amount,
  public.competition_tv_away_share(gs.tv_per_match_amount) AS away_tv_amount,
  gs.tv_per_match_amount AS amount_per_club
FROM public.competition_tv_fixture_selection s
JOIN public.competition_fixtures f ON f.id = s.fixture_id
CROSS JOIN public.global_settings gs
WHERE gs.id = 1;

GRANT SELECT ON public.competition_tv_fixtures_public TO authenticated;
GRANT SELECT ON public.competition_tv_fixtures_public TO anon;

-- ---------------------------------------------------------------------------
-- Backfill legacy full-payout TV rows to 80/20 split
-- ---------------------------------------------------------------------------

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