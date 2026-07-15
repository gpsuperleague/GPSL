-- =============================================================================
-- Cup finals: always sellout gate at Wembley capacity
--
-- 90,000 × 100% × ₿20 = ₿1,800,000 total → ₿900,000 each (50/50)
--
-- Also re-applies gate corrections for already-settled finals.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_cup_final_expected_gate(p_fixture_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_capacity int;
  v_venue text;
  v_price numeric := 20;
  v_total numeric;
  v_home_share numeric;
  v_away_share numeric;
  v_breakdown jsonb;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND OR NOT public.competition_fixture_is_cup_final(v_fixture) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_cup_final');
  END IF;

  SELECT
    coalesce(nullif(btrim(gs.cup_final_venue_name), ''), 'Wembley Stadium'),
    greatest(coalesce(gs.cup_final_venue_capacity, 90000), 1)
  INTO v_venue, v_capacity
  FROM public.global_settings gs
  WHERE gs.id = 1;

  v_venue := coalesce(nullif(btrim(v_fixture.venue_name), ''), v_venue, 'Wembley Stadium');
  v_capacity := coalesce(nullif(v_fixture.venue_capacity, 0), v_capacity, 90000);

  -- Cup finals are always a sellout
  v_total := round(v_capacity * 1.0 * v_price);
  v_home_share := round(v_total / 2.0, 2);
  v_away_share := v_total - v_home_share;

  v_breakdown := jsonb_build_object(
    'capacity', v_capacity,
    'attendance_rate', 1.0,
    'gate_fill_pct', 100,
    'gate_attendance_rate', 1.0,
    'price_per_seat', v_price,
    'total_gate', v_total,
    'venue_name', v_venue,
    'neutral_final', true,
    'cup_final_sellout', true
  );

  RETURN jsonb_build_object(
    'ok', true,
    'venue_name', v_venue,
    'capacity', v_capacity,
    'total_gate', v_total,
    'home_share', v_home_share,
    'away_share', v_away_share,
    'gate_fill_pct', 100,
    'breakdown', v_breakdown
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_settle_fixture_gates(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_capacity int;
  v_pos int;
  v_hist numeric;
  v_breakdown jsonb;
  v_total numeric;
  v_home_share numeric;
  v_away_share numeric;
  v_desc text;
  v_home_club text;
  v_away_club text;
  v_division text;
  v_gate_pct numeric;
  v_is_final boolean := false;
  v_venue text;
  v_price numeric := 20;
  v_expected jsonb;
BEGIN
  IF p_fixture_id IS NULL THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_finance_ledger
    WHERE fixture_id = p_fixture_id
      AND entry_type IN ('gate_league_home', 'gate_cup_share')
  ) THEN
    RETURN;
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
    AND status = 'played'
    AND home_goals IS NOT NULL
    AND away_goals IS NOT NULL;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_home_club := v_fixture.home_club_short_name;
  v_away_club := v_fixture.away_club_short_name;
  v_is_final := public.competition_fixture_is_cup_final(v_fixture);

  IF v_is_final THEN
    PERFORM public.competition_apply_cup_final_venue(p_fixture_id);
    SELECT * INTO v_fixture
    FROM public.competition_fixtures
    WHERE id = p_fixture_id;

    v_expected := public.competition_cup_final_expected_gate(p_fixture_id);
    IF coalesce((v_expected ->> 'ok')::boolean, false) IS NOT TRUE THEN
      RETURN;
    END IF;

    v_capacity := (v_expected ->> 'capacity')::int;
    v_venue := v_expected ->> 'venue_name';
    v_breakdown := v_expected -> 'breakdown';
    v_total := (v_expected ->> 'total_gate')::numeric;
    v_gate_pct := 100;
  ELSE
    IF v_fixture.competition_type = 'cup' THEN
      SELECT ccs.division INTO v_division
      FROM public.competition_club_seasons ccs
      WHERE ccs.season_id = v_fixture.season_id
        AND ccs.club_short_name = v_home_club;
    ELSE
      v_division := v_fixture.division;
    END IF;

    v_division := coalesce(v_division, 'superleague');

    SELECT coalesce(c."Capacity", 0)::int INTO v_capacity
    FROM public."Clubs" c
    WHERE c."ShortName" = v_home_club;

    v_pos := public.competition_club_table_position(
      v_fixture.season_id,
      v_division,
      v_home_club
    );
    v_hist := public.competition_club_history_avg_position(v_home_club, 5);
    v_breakdown := public.competition_compute_gate_total(
      v_capacity,
      v_pos,
      v_hist,
      v_home_club,
      v_fixture.season_id,
      v_division
    );
    v_total := (v_breakdown ->> 'total_gate')::numeric;
    v_gate_pct := coalesce(
      (v_breakdown ->> 'gate_fill_pct')::numeric,
      round((v_breakdown ->> 'attendance_rate')::numeric * 100, 1)
    );
  END IF;

  IF v_total IS NULL OR v_total <= 0 THEN
    RETURN;
  END IF;

  IF v_fixture.competition_type = 'league' THEN
    v_desc := format(
      'Gate MD%s — %s vs %s (home 100%%) · gate fill %s%%',
      v_fixture.matchday,
      v_home_club,
      v_away_club,
      v_gate_pct
    );

    PERFORM public.competition_credit_club_balance(v_home_club, v_total);

    INSERT INTO public.competition_finance_ledger (
      season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
    )
    VALUES (
      v_fixture.season_id,
      p_fixture_id,
      v_home_club,
      'gate_league_home',
      v_total,
      v_desc,
      v_breakdown
    );
  ELSIF v_fixture.competition_type = 'cup' THEN
    v_home_share := round(v_total / 2.0, 2);
    v_away_share := v_total - v_home_share;

    IF v_is_final THEN
      v_desc := format(
        '%s Final — %s vs %s at %s (50/50 gate · sellout · cap %s)',
        upper(v_fixture.cup_code),
        v_home_club,
        v_away_club,
        v_venue,
        v_capacity
      );
    ELSE
      v_desc := format(
        '%s R%s — %s vs %s (50/50 gate)',
        upper(v_fixture.cup_code),
        v_fixture.cup_round,
        v_home_club,
        v_away_club
      );
    END IF;

    PERFORM public.competition_credit_club_balance(v_home_club, v_home_share);
    PERFORM public.competition_credit_club_balance(v_away_club, v_away_share);

    INSERT INTO public.competition_finance_ledger (
      season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
    )
    VALUES
      (
        v_fixture.season_id,
        p_fixture_id,
        v_home_club,
        'gate_cup_share',
        v_home_share,
        v_desc || ' (home)',
        v_breakdown
      ),
      (
        v_fixture.season_id,
        p_fixture_id,
        v_away_club,
        'gate_cup_share',
        v_away_share,
        v_desc || ' (away)',
        v_breakdown
      );
  END IF;
END;
$function$;

-- Ensure backfill helper uses sellout expected gate + UPDATE (not insert)
CREATE OR REPLACE FUNCTION public.competition_admin_backfill_cup_final_gates(
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
  v_expected jsonb;
  v_home_target numeric;
  v_away_target numeric;
  v_home_paid numeric;
  v_away_paid numeric;
  v_home_delta numeric;
  v_away_delta numeric;
  v_scanned int := 0;
  v_adjusted int := 0;
  v_skipped int := 0;
  v_preview jsonb := '[]'::jsonb;
  v_desc text;
  v_meta jsonb;
  v_venue text;
  v_cap int;
  v_total numeric;
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
    FROM public.competition_fixtures f
    WHERE f.season_id = v_season_id
      AND f.competition_type = 'cup'
      AND f.status = 'played'
      AND public.competition_fixture_is_cup_final(f)
      AND EXISTS (
        SELECT 1
        FROM public.competition_finance_ledger l
        WHERE l.fixture_id = f.id
          AND l.entry_type = 'gate_cup_share'
      )
    ORDER BY f.cup_code, f.id
  LOOP
    v_scanned := v_scanned + 1;

    IF NOT p_dry_run THEN
      PERFORM public.competition_apply_cup_final_venue(v_fixture.id);
      SELECT * INTO v_fixture FROM public.competition_fixtures WHERE id = v_fixture.id;
    END IF;

    v_expected := public.competition_cup_final_expected_gate(v_fixture.id);
    IF coalesce((v_expected ->> 'ok')::boolean, false) IS NOT TRUE THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_home_target := (v_expected ->> 'home_share')::numeric;
    v_away_target := (v_expected ->> 'away_share')::numeric;
    v_venue := v_expected ->> 'venue_name';
    v_cap := (v_expected ->> 'capacity')::int;
    v_total := (v_expected ->> 'total_gate')::numeric;

    SELECT coalesce(sum(l.amount), 0)
    INTO v_home_paid
    FROM public.competition_finance_ledger l
    WHERE l.fixture_id = v_fixture.id
      AND l.club_short_name = v_fixture.home_club_short_name
      AND l.entry_type = 'gate_cup_share';

    SELECT coalesce(sum(l.amount), 0)
    INTO v_away_paid
    FROM public.competition_finance_ledger l
    WHERE l.fixture_id = v_fixture.id
      AND l.club_short_name = v_fixture.away_club_short_name
      AND l.entry_type = 'gate_cup_share';

    v_home_delta := round(v_home_target - v_home_paid, 2);
    v_away_delta := round(v_away_target - v_away_paid, 2);

    IF abs(coalesce(v_home_delta, 0)) < 0.01 AND abs(coalesce(v_away_delta, 0)) < 0.01 THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_preview := v_preview || jsonb_build_array(
      jsonb_build_object(
        'fixture_id', v_fixture.id,
        'cup_code', v_fixture.cup_code,
        'home', v_fixture.home_club_short_name,
        'away', v_fixture.away_club_short_name,
        'venue', v_venue,
        'capacity', v_cap,
        'total_gate', v_total,
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

    v_desc := format(
      '%s Final — %s vs %s at %s (50/50 gate · sellout · cap %s)',
      upper(v_fixture.cup_code),
      v_fixture.home_club_short_name,
      v_fixture.away_club_short_name,
      v_venue,
      v_cap
    );
    v_meta := (v_expected -> 'breakdown') || jsonb_build_object(
      'wembley_gate_backfill', true,
      'cup_final_sellout', true,
      'prior_home_paid', v_home_paid,
      'prior_away_paid', v_away_paid,
      'target_home_share', v_home_target,
      'target_away_share', v_away_target
    );

    IF abs(v_home_delta) >= 0.01 THEN
      PERFORM public.competition_credit_club_balance(
        v_fixture.home_club_short_name,
        v_home_delta
      );
      UPDATE public.competition_finance_ledger
      SET amount = v_home_target,
          description = v_desc || ' (home)',
          metadata = coalesce(metadata, '{}'::jsonb) || v_meta
            || jsonb_build_object(
              'role', 'home',
              'correction_delta', v_home_delta,
              'prior_amount', v_home_paid
            )
      WHERE fixture_id = v_fixture.id
        AND club_short_name = v_fixture.home_club_short_name
        AND entry_type = 'gate_cup_share';
    END IF;

    IF abs(v_away_delta) >= 0.01 THEN
      PERFORM public.competition_credit_club_balance(
        v_fixture.away_club_short_name,
        v_away_delta
      );
      UPDATE public.competition_finance_ledger
      SET amount = v_away_target,
          description = v_desc || ' (away)',
          metadata = coalesce(metadata, '{}'::jsonb) || v_meta
            || jsonb_build_object(
              'role', 'away',
              'correction_delta', v_away_delta,
              'prior_amount', v_away_paid
            )
      WHERE fixture_id = v_fixture.id
        AND club_short_name = v_fixture.away_club_short_name
        AND entry_type = 'gate_cup_share';
    END IF;

    v_adjusted := v_adjusted + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'dry_run', p_dry_run,
    'season_id', v_season_id,
    'finals_with_gate_scanned', v_scanned,
    'finals_adjusted', v_adjusted,
    'finals_already_correct_or_skipped', v_skipped,
    'details', v_preview
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_cup_final_expected_gate(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_backfill_cup_final_gates(bigint, boolean) TO authenticated;

-- Top up existing finals to sellout (₿900,000 each at 90k capacity)
SELECT public.competition_admin_backfill_cup_final_gates(NULL::bigint, false);

NOTIFY pgrst, 'reload schema';
