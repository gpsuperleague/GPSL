-- =============================================================================
-- Cup finals — backfill Wembley gate receipts (and re-stamp venue)
--
-- Corrects already-settled gate_cup_share rows that used home stadium capacity
-- instead of Wembley (90,000). Credits the balance delta and UPDATES the
-- existing ledger row (unique on fixture/club/entry_type — no second insert).
--
-- Preview (SQL Editor):
--   SELECT public.competition_admin_backfill_cup_final_gates(NULL::bigint, true);
-- Apply:
--   SELECT public.competition_admin_backfill_cup_final_gates(NULL::bigint, false);
--
-- This file also runs apply for the current season at the end.
-- Safe re-run (idempotent: only posts when paid ≠ expected).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_fixture_is_cup_final(
  p_fixture public.competition_fixtures
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT coalesce(p_fixture.competition_type, '') = 'cup'
    AND p_fixture.cup_code IS NOT NULL
    AND p_fixture.cup_round IS NOT NULL
    AND (
      EXISTS (
        SELECT 1
        FROM public.competition_cup_round_schedule s
        WHERE s.cup_code = p_fixture.cup_code
          AND s.round_no = p_fixture.cup_round::smallint
          AND s.stage = 'final'
      )
      OR p_fixture.cup_round = (
        SELECT max(n.round_no)
        FROM public.competition_cup_bracket_nodes n
        WHERE n.season_id = p_fixture.season_id
          AND n.cup_code = p_fixture.cup_code
      )
      OR p_fixture.cup_round = (
        SELECT max(s.round_no)
        FROM public.competition_cup_round_schedule s
        WHERE s.cup_code = p_fixture.cup_code
      )
      OR lower(coalesce(
        (
          SELECT s.round_label
          FROM public.competition_cup_round_schedule s
          WHERE s.cup_code = p_fixture.cup_code
            AND s.round_no = p_fixture.cup_round::smallint
          ORDER BY s.cup_leg DESC
          LIMIT 1
        ),
        ''
      )) LIKE '%final%'
    );
$$;

CREATE OR REPLACE FUNCTION public.competition_apply_cup_final_venue(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_name text;
  v_cap int;
BEGIN
  IF p_fixture_id IS NULL THEN
    RETURN;
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id;

  IF NOT FOUND OR NOT public.competition_fixture_is_cup_final(v_fixture) THEN
    RETURN;
  END IF;

  SELECT
    coalesce(nullif(btrim(gs.cup_final_venue_name), ''), 'Wembley Stadium'),
    greatest(coalesce(gs.cup_final_venue_capacity, 90000), 1)
  INTO v_name, v_cap
  FROM public.global_settings gs
  WHERE gs.id = 1;

  v_name := coalesce(v_name, 'Wembley Stadium');
  v_cap := coalesce(v_cap, 90000);

  UPDATE public.competition_fixtures
  SET venue_name = v_name,
      venue_capacity = v_cap
  WHERE id = p_fixture_id;
END;
$function$;

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
  v_division text;
  v_pos int;
  v_hist numeric;
  v_breakdown jsonb;
  v_total numeric;
  v_home_share numeric;
  v_away_share numeric;
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

  SELECT ccs.division INTO v_division
  FROM public.competition_club_seasons ccs
  WHERE ccs.season_id = v_fixture.season_id
    AND ccs.club_short_name = v_fixture.home_club_short_name;

  v_division := coalesce(v_division, 'superleague');

  v_pos := public.competition_club_table_position(
    v_fixture.season_id,
    v_division,
    v_fixture.home_club_short_name
  );
  v_hist := public.competition_club_history_avg_position(v_fixture.home_club_short_name, 5);
  v_breakdown := public.competition_compute_gate_total(
    v_capacity,
    v_pos,
    v_hist,
    v_fixture.home_club_short_name,
    v_fixture.season_id,
    v_division
  ) || jsonb_build_object(
    'venue_name', v_venue,
    'neutral_final', true,
    'capacity', v_capacity
  );

  v_total := (v_breakdown ->> 'total_gate')::numeric;
  IF v_total IS NULL OR v_total <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'zero_gate', 'breakdown', v_breakdown);
  END IF;

  v_home_share := round(v_total / 2.0, 2);
  v_away_share := v_total - v_home_share;

  RETURN jsonb_build_object(
    'ok', true,
    'venue_name', v_venue,
    'capacity', v_capacity,
    'total_gate', v_total,
    'home_share', v_home_share,
    'away_share', v_away_share,
    'gate_fill_pct', coalesce(
      (v_breakdown ->> 'gate_fill_pct')::numeric,
      round((v_breakdown ->> 'attendance_rate')::numeric * 100, 1)
    ),
    'breakdown', v_breakdown
  );
END;
$function$;

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

  -- Ensure venue columns / settings exist
  BEGIN
    ALTER TABLE public.competition_fixtures
      ADD COLUMN IF NOT EXISTS venue_name text,
      ADD COLUMN IF NOT EXISTS venue_capacity integer;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  BEGIN
    ALTER TABLE public.global_settings
      ADD COLUMN IF NOT EXISTS cup_final_venue_name text NOT NULL DEFAULT 'Wembley Stadium',
      ADD COLUMN IF NOT EXISTS cup_final_venue_capacity integer NOT NULL DEFAULT 90000;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

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
      '%s Final Wembley gate correction — %s vs %s at %s (50/50 · cap %s)',
      upper(v_fixture.cup_code),
      v_fixture.home_club_short_name,
      v_fixture.away_club_short_name,
      v_venue,
      v_cap
    );
    v_meta := (v_expected -> 'breakdown') || jsonb_build_object(
      'wembley_gate_backfill', true,
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

GRANT EXECUTE ON FUNCTION public.competition_fixture_is_cup_final(public.competition_fixtures) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_apply_cup_final_venue(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_cup_final_expected_gate(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_backfill_cup_final_gates(bigint, boolean) TO authenticated;

-- Apply for current season (set true first if you want a preview-only run)
SELECT public.competition_admin_backfill_cup_final_gates(NULL::bigint, false);

NOTIFY pgrst, 'reload schema';
