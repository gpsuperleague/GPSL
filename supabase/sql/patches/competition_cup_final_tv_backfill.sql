-- =============================================================================
-- Cup finals TV: always selected, always paid 50/50, backfill existing
--
-- Each finalist receives half of global_settings.tv_per_match_amount.
-- (Default schema is ₿1,000,000 → ₿500,000 each. Set pool to ₿3,000,000
--  in Admin → TV revenue if you want ₿1,500,000 each.)
--
-- Unique (fixture, club, entry_type) → UPDATE existing tv_revenue rows +
-- credit balance deltas (same pattern as Wembley gate backfill).
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_tv_ensure_cup_final_selected(p_fixture_id bigint)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_div text;
BEGIN
  IF p_fixture_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND OR NOT public.competition_fixture_is_cup_final(v_fixture) THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_tv_fixture_selection s
    WHERE s.fixture_id = p_fixture_id
  ) THEN
    RETURN true;
  END IF;

  v_div := public.competition_tv_fixture_effective_division(v_fixture);

  INSERT INTO public.competition_tv_fixture_selection (
    season_id, fixture_id, division, gpsl_month, tv_score, reasons
  )
  VALUES (
    v_fixture.season_id,
    p_fixture_id,
    coalesce(v_div, 'superleague'),
    v_fixture.gpsl_month,
    9999,
    jsonb_build_array('cup_final_guaranteed')
  )
  ON CONFLICT ON CONSTRAINT competition_tv_fixture_selection_unique DO NOTHING;

  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_backfill_cup_final_tv(
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
  v_home_target numeric;
  v_away_target numeric;
  v_home_paid numeric;
  v_away_paid numeric;
  v_home_delta numeric;
  v_away_delta numeric;
  v_scanned int := 0;
  v_selected int := 0;
  v_adjusted int := 0;
  v_skipped int := 0;
  v_preview jsonb := '[]'::jsonb;
  v_desc text;
  v_meta jsonb;
  v_label text;
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

  v_pool := (SELECT tv_per_match_amount FROM public.global_settings WHERE id = 1);
  IF v_pool IS NULL OR v_pool <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_tv_pool', 'tv_per_match_amount', v_pool);
  END IF;

  v_home_target := round(v_pool / 2.0, 2);
  v_away_target := v_pool - v_home_target;

  -- All finals (played or not): guarantee TV selection
  FOR v_fixture IN
    SELECT f.*
    FROM public.competition_fixtures f
    WHERE f.season_id = v_season_id
      AND f.competition_type = 'cup'
      AND public.competition_fixture_is_cup_final(f)
    ORDER BY f.cup_code, f.id
  LOOP
    v_scanned := v_scanned + 1;

    IF NOT p_dry_run THEN
      IF public.competition_tv_ensure_cup_final_selected(v_fixture.id) THEN
        v_selected := v_selected + 1;
      END IF;
    ELSE
      v_selected := v_selected + 1;
    END IF;

    -- Payout only once played
    IF v_fixture.status IS DISTINCT FROM 'played'
       OR v_fixture.home_goals IS NULL
       OR v_fixture.away_goals IS NULL THEN
      CONTINUE;
    END IF;

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

    v_home_delta := round(v_home_target - v_home_paid, 2);
    v_away_delta := round(v_away_target - v_away_paid, 2);

    IF abs(coalesce(v_home_delta, 0)) < 0.01 AND abs(coalesce(v_away_delta, 0)) < 0.01
       AND v_home_paid > 0 AND v_away_paid > 0 THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_preview := v_preview || jsonb_build_array(
      jsonb_build_object(
        'fixture_id', v_fixture.id,
        'cup_code', v_fixture.cup_code,
        'home', v_fixture.home_club_short_name,
        'away', v_fixture.away_club_short_name,
        'tv_pool', v_pool,
        'home_paid', v_home_paid,
        'away_paid', v_away_paid,
        'home_target', v_home_target,
        'away_target', v_away_target,
        'home_delta', v_home_delta,
        'away_delta', v_away_delta
      )
    );

    IF p_dry_run THEN
      v_adjusted := v_adjusted + 1;
      CONTINUE;
    END IF;

    v_label := public.competition_tv_fixture_settle_label(v_fixture);
    v_desc := format(
      'TV revenue (cup final 50/50) %s — %s vs %s',
      v_label,
      v_fixture.home_club_short_name,
      v_fixture.away_club_short_name
    );
    v_meta := jsonb_build_object(
      'gpsl_month', v_fixture.gpsl_month,
      'tv_share_pct', 50,
      'tv_match_pool', v_pool,
      'competition_type', 'cup',
      'cup_code', v_fixture.cup_code,
      'neutral_final', true,
      'cup_final_tv_backfill', true
    );

    -- Home
    IF NOT EXISTS (
      SELECT 1 FROM public.competition_finance_ledger
      WHERE fixture_id = v_fixture.id
        AND club_short_name = v_fixture.home_club_short_name
        AND entry_type = 'tv_revenue'
    ) THEN
      PERFORM public.competition_credit_club_balance(
        v_fixture.home_club_short_name,
        v_home_target
      );
      INSERT INTO public.competition_finance_ledger (
        season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
      )
      VALUES (
        v_fixture.season_id,
        v_fixture.id,
        v_fixture.home_club_short_name,
        'tv_revenue',
        v_home_target,
        v_desc || ' (home)',
        v_meta || jsonb_build_object('role', 'home')
      );
    ELSIF abs(v_home_delta) >= 0.01 THEN
      PERFORM public.competition_credit_club_balance(
        v_fixture.home_club_short_name,
        v_home_delta
      );
      UPDATE public.competition_finance_ledger
      SET amount = v_home_target,
          description = v_desc || ' (home)',
          metadata = coalesce(metadata, '{}'::jsonb) || v_meta
            || jsonb_build_object('role', 'home', 'correction_delta', v_home_delta, 'prior_amount', v_home_paid)
      WHERE fixture_id = v_fixture.id
        AND club_short_name = v_fixture.home_club_short_name
        AND entry_type = 'tv_revenue';
    END IF;

    -- Away
    IF NOT EXISTS (
      SELECT 1 FROM public.competition_finance_ledger
      WHERE fixture_id = v_fixture.id
        AND club_short_name = v_fixture.away_club_short_name
        AND entry_type = 'tv_revenue'
    ) THEN
      PERFORM public.competition_credit_club_balance(
        v_fixture.away_club_short_name,
        v_away_target
      );
      INSERT INTO public.competition_finance_ledger (
        season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
      )
      VALUES (
        v_fixture.season_id,
        v_fixture.id,
        v_fixture.away_club_short_name,
        'tv_revenue',
        v_away_target,
        v_desc || ' (away)',
        v_meta || jsonb_build_object('role', 'away')
      );
    ELSIF abs(v_away_delta) >= 0.01 THEN
      PERFORM public.competition_credit_club_balance(
        v_fixture.away_club_short_name,
        v_away_delta
      );
      UPDATE public.competition_finance_ledger
      SET amount = v_away_target,
          description = v_desc || ' (away)',
          metadata = coalesce(metadata, '{}'::jsonb) || v_meta
            || jsonb_build_object('role', 'away', 'correction_delta', v_away_delta, 'prior_amount', v_away_paid)
      WHERE fixture_id = v_fixture.id
        AND club_short_name = v_fixture.away_club_short_name
        AND entry_type = 'tv_revenue';
    END IF;

    v_adjusted := v_adjusted + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'season_id', v_season_id,
    'tv_per_match_amount', v_pool,
    'per_finalist_target', v_home_target,
    'finals_scanned', v_scanned,
    'finals_ensured_selected', v_selected,
    'finals_tv_adjusted', v_adjusted,
    'finals_already_correct', v_skipped,
    'details', v_preview
  );
END;
$function$;

-- Keep settle path on 50/50 for finals (in case an older settle overwrite exists)
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

  v_pool := (SELECT tv_per_match_amount FROM public.global_settings WHERE id = 1);

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
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_tv_ensure_cup_final_selected(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_backfill_cup_final_tv(bigint, boolean) TO authenticated;

SELECT public.competition_admin_backfill_cup_final_tv(NULL::bigint, false);

NOTIFY pgrst, 'reload schema';
