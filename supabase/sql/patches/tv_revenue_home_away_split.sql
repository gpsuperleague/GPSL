-- =============================================================================
-- TV revenue: 80% home / 20% away of tv_per_match_amount (single match pool).
-- Run after competition_tv_revenue.sql and central_bank_model_a_flows.sql
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

NOTIFY pgrst, 'reload schema';
