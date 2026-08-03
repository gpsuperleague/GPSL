-- =============================================================================
-- Season 2 TV revenue backfill
--
-- Symptom: fixture shows 📺 (in competition_tv_fixture_selection) but Season
-- accounts → Prize money & TV → TV revenue is empty.
--
-- Cause (usual):
--   • TV amounts were 0 / unset when the match was confirmed → settle no-oped
--   • OR TV selection happened after the fixture was already played → settle
--     never re-ran
-- Badge ≠ money. Money is posted by competition_tv_settle_fixture().
--
-- This script:
--   1) Restores cup-aware settle (league pool vs cup pool; finals 50/50)
--   2) Resolves Season 2
--   3) Diagnoses Jubilo / unpaid TV selections
--   4) Runs competition_admin_backfill_tv_revenue for Season 2
--
-- Idempotent. Safe re-run.
-- Prefer also: Admin → Set TV Revenue → “Backfill TV revenue” (same RPC).
-- =============================================================================

-- Pool for unpaid fixtures: use cup amount for cup ties
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
      SELECT CASE
        WHEN f.competition_type = 'cup' THEN
          coalesce(gs.tv_cup_per_match_amount, gs.tv_per_match_amount)
        ELSE gs.tv_per_match_amount
      END
      FROM public.competition_fixtures f
      CROSS JOIN public.global_settings gs
      WHERE f.id = p_fixture_id
        AND gs.id = 1
    )
  );
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
  v_label text;
  v_meta jsonb;
  v_is_final boolean := false;
  v_home_pct int;
  v_away_pct int;
BEGIN
  IF p_fixture_id IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
    AND competition_type IN ('league', 'cup')
    AND status = 'played'
    AND home_goals IS NOT NULL
    AND away_goals IS NOT NULL;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_is_final := public.competition_fixture_is_cup_final(v_fixture);
  IF v_is_final THEN
    PERFORM public.competition_tv_ensure_cup_final_selected(p_fixture_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_tv_fixture_selection WHERE fixture_id = p_fixture_id
  ) THEN
    RETURN;
  END IF;

  SELECT
    CASE
      WHEN v_fixture.competition_type = 'cup' THEN
        coalesce(gs.tv_cup_per_match_amount, gs.tv_per_match_amount)
      ELSE gs.tv_per_match_amount
    END
  INTO v_pool
  FROM public.global_settings gs
  WHERE gs.id = 1;

  IF v_pool IS NULL OR v_pool <= 0 THEN
    RETURN;
  END IF;

  IF v_is_final THEN
    v_home_amount := round(v_pool / 2.0, 2);
    v_away_amount := v_pool - v_home_amount;
    v_home_pct := 50;
    v_away_pct := 50;
  ELSE
    v_home_amount := public.competition_tv_home_share(v_pool);
    v_away_amount := public.competition_tv_away_share(v_pool);
    v_home_pct := 80;
    v_away_pct := 20;
  END IF;

  v_label := public.competition_tv_fixture_settle_label(v_fixture);

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_finance_ledger
    WHERE fixture_id = p_fixture_id
      AND club_short_name = v_fixture.home_club_short_name
      AND entry_type = 'tv_revenue'
  ) THEN
    v_desc := format(
      'TV revenue (home %s%%) %s — %s vs %s',
      v_home_pct,
      v_label,
      v_fixture.home_club_short_name,
      v_fixture.away_club_short_name
    );
    v_meta := jsonb_build_object(
      'gpsl_month', v_fixture.gpsl_month,
      'role', 'home',
      'tv_share_pct', v_home_pct,
      'tv_match_pool', v_pool,
      'competition_type', v_fixture.competition_type,
      'cup_code', v_fixture.cup_code,
      'neutral_final', v_is_final
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
      'TV revenue (away %s%%) %s — %s vs %s',
      v_away_pct,
      v_label,
      v_fixture.home_club_short_name,
      v_fixture.away_club_short_name
    );
    v_meta := jsonb_build_object(
      'gpsl_month', v_fixture.gpsl_month,
      'role', 'away',
      'tv_share_pct', v_away_pct,
      'tv_match_pool', v_pool,
      'competition_type', v_fixture.competition_type,
      'cup_code', v_fixture.cup_code,
      'neutral_final', v_is_final
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

GRANT EXECUTE ON FUNCTION public.competition_tv_settle_fixture(bigint)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- One-shot Season 2 runner
-- ---------------------------------------------------------------------------
DO $season2_tv$
DECLARE
  v_s2 bigint;
  v_s2_label text;
  v_league_pool numeric;
  v_cup_pool numeric;
  v_selected int;
  v_played_selected int;
  v_unpaid int;
  v_result jsonb;
  v_jubilo text;
  v_jubilo_paid numeric;
  v_jubilo_tv_rows int;
  r record;
BEGIN
  SELECT id, label INTO v_s2, v_s2_label
  FROM public.competition_seasons
  WHERE lower(btrim(label)) IN ('2', 'season 2', 's2')
     OR label = '2'
  ORDER BY id DESC
  LIMIT 1;

  IF v_s2 IS NULL THEN
    SELECT id, label INTO v_s2, v_s2_label
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
    RAISE NOTICE 'No season labelled 2 — using current id=% label=%', v_s2, v_s2_label;
  ELSE
    RAISE NOTICE 'Season 2 resolved: id=% label=%', v_s2, v_s2_label;
  END IF;

  IF v_s2 IS NULL THEN
    RAISE EXCEPTION 'Could not resolve Season 2';
  END IF;

  SELECT gs.tv_per_match_amount, coalesce(gs.tv_cup_per_match_amount, gs.tv_per_match_amount)
  INTO v_league_pool, v_cup_pool
  FROM public.global_settings gs
  WHERE gs.id = 1;

  RAISE NOTICE 'TV pools: league=₿% cup=₿%',
    coalesce(v_league_pool, 0), coalesce(v_cup_pool, 0);

  IF coalesce(v_league_pool, 0) <= 0 AND coalesce(v_cup_pool, 0) <= 0 THEN
    RAISE EXCEPTION
      'Both league and cup TV pools are 0. Set them in Admin → TV Revenue, then re-run.';
  END IF;

  SELECT count(*)::int INTO v_selected
  FROM public.competition_tv_fixture_selection s
  WHERE s.season_id = v_s2;

  SELECT count(*)::int INTO v_played_selected
  FROM public.competition_tv_fixture_selection s
  JOIN public.competition_fixtures f ON f.id = s.fixture_id
  WHERE s.season_id = v_s2
    AND f.status = 'played';

  SELECT count(*)::int INTO v_unpaid
  FROM public.competition_tv_fixture_selection s
  JOIN public.competition_fixtures f ON f.id = s.fixture_id
  WHERE s.season_id = v_s2
    AND f.status = 'played'
    AND NOT EXISTS (
      SELECT 1
      FROM public.competition_finance_ledger l
      WHERE l.fixture_id = f.id
        AND l.entry_type = 'tv_revenue'
    );

  RAISE NOTICE 'Season 2 TV selections=% played=% unpaid_ledger=%',
    v_selected, v_played_selected, v_unpaid;

  -- Jubilo diagnostic
  SELECT c."ShortName" INTO v_jubilo
  FROM public."Clubs" c
  WHERE lower(c."ShortName") LIKE '%jubilo%'
     OR lower(c."ShortName") LIKE '%júbilo%'
     OR lower(coalesce(c."Club", '')) LIKE '%jubilo%'
  ORDER BY c."ShortName"
  LIMIT 1;

  IF v_jubilo IS NULL THEN
    RAISE NOTICE 'Could not resolve Jubilo club short_name — skipping club detail.';
  ELSE
    RAISE NOTICE 'Jubilo club short_name=%', v_jubilo;

    RAISE NOTICE '--- Jubilo Season 2 TV selections ---';
    FOR r IN
      SELECT
        f.id AS fixture_id,
        f.gpsl_month,
        f.competition_type,
        f.cup_code,
        f.status,
        f.home_club_short_name || ' vs ' || f.away_club_short_name AS fixture,
        EXISTS (
          SELECT 1 FROM public.competition_finance_ledger l
          WHERE l.fixture_id = f.id
            AND l.club_short_name = v_jubilo
            AND l.entry_type = 'tv_revenue'
        ) AS paid_for_jubilo
      FROM public.competition_tv_fixture_selection s
      JOIN public.competition_fixtures f ON f.id = s.fixture_id
      WHERE s.season_id = v_s2
        AND (
          f.home_club_short_name = v_jubilo
          OR f.away_club_short_name = v_jubilo
        )
      ORDER BY f.gpsl_month, f.id
    LOOP
      RAISE NOTICE '  id=% % %/% status=% paid=% — %',
        r.fixture_id, r.gpsl_month, r.competition_type, coalesce(r.cup_code, '-'),
        r.status, r.paid_for_jubilo, r.fixture;
    END LOOP;

    SELECT count(*)::int, coalesce(sum(l.amount), 0)
    INTO v_jubilo_tv_rows, v_jubilo_paid
    FROM public.competition_finance_ledger l
    WHERE l.season_id = v_s2
      AND l.club_short_name = v_jubilo
      AND l.entry_type = 'tv_revenue';

    RAISE NOTICE 'Jubilo BEFORE backfill: tv_ledger_rows=% total=₿%',
      v_jubilo_tv_rows, v_jubilo_paid;
  END IF;

  IF to_regprocedure('public.competition_admin_backfill_tv_revenue(bigint)') IS NULL THEN
    RAISE EXCEPTION 'competition_admin_backfill_tv_revenue missing — run competition_tv_revenue.sql first.';
  END IF;

  v_result := public.competition_admin_backfill_tv_revenue(v_s2);
  RAISE NOTICE 'Backfill result: %', v_result;

  IF v_jubilo IS NOT NULL THEN
    SELECT count(*)::int, coalesce(sum(l.amount), 0)
    INTO v_jubilo_tv_rows, v_jubilo_paid
    FROM public.competition_finance_ledger l
    WHERE l.season_id = v_s2
      AND l.club_short_name = v_jubilo
      AND l.entry_type = 'tv_revenue';

    RAISE NOTICE 'Jubilo AFTER backfill: tv_ledger_rows=% total=₿%',
      v_jubilo_tv_rows, v_jubilo_paid;
  END IF;

  SELECT count(*)::int INTO v_unpaid
  FROM public.competition_tv_fixture_selection s
  JOIN public.competition_fixtures f ON f.id = s.fixture_id
  WHERE s.season_id = v_s2
    AND f.status = 'played'
    AND NOT EXISTS (
      SELECT 1
      FROM public.competition_finance_ledger l
      WHERE l.fixture_id = f.id
        AND l.entry_type = 'tv_revenue'
    );

  RAISE NOTICE 'Season 2 unpaid TV fixtures remaining: %', v_unpaid;
END;
$season2_tv$;

NOTIFY pgrst, 'reload schema';

-- Optional checks:
-- SELECT f.id, f.gpsl_month, f.cup_code, f.home_club_short_name, f.away_club_short_name, f.status
-- FROM competition_tv_fixture_selection s
-- JOIN competition_fixtures f ON f.id = s.fixture_id
-- WHERE s.season_id = (SELECT id FROM competition_seasons WHERE label IN ('2','Season 2') LIMIT 1)
--   AND (f.home_club_short_name ILIKE '%jubilo%' OR f.away_club_short_name ILIKE '%jubilo%');
--
-- SELECT * FROM competition_finance_ledger
-- WHERE season_id = (SELECT id FROM competition_seasons WHERE label IN ('2','Season 2') LIMIT 1)
--   AND club_short_name ILIKE '%jubilo%'
--   AND entry_type = 'tv_revenue';
