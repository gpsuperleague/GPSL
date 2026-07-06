-- =============================================================================
-- Cup prizes skipped on penalty/level-score ties (admin test deploy + confirm).
-- Also backfill played cup ties that never received prize_cup ledger lines.
-- Run after competition_cup_prizes_fix.sql and central_bank_model_a_flows.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_pay_cup_fixture_prizes(p_fixture_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_max_round int;
  v_stage text;
  v_amount numeric;
  v_club text;
  v_cup_label text;
  v_stage_label text;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id AND competition_type = 'cup';

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_fixture.home_goals IS NOT DISTINCT FROM v_fixture.away_goals
     AND coalesce(btrim(v_fixture.cup_pen_winner_club_short_name), '') = '' THEN
    RETURN;
  END IF;

  SELECT max(round_no) INTO v_max_round
  FROM public.competition_cup_bracket_nodes
  WHERE season_id = v_fixture.season_id AND cup_code = v_fixture.cup_code;

  v_stage := public.competition_cup_round_stage(
    v_fixture.cup_code,
    v_fixture.cup_round,
    coalesce(v_max_round, v_fixture.cup_round)
  );

  v_cup_label := upper(replace(coalesce(v_fixture.cup_code, 'cup'), '_', ' '));
  v_stage_label := CASE v_stage
    WHEN 'r1' THEN 'Round 1'
    WHEN 'r2' THEN 'Round 2'
    WHEN 'qf' THEN 'Quarter-final'
    WHEN 'sf' THEN 'Semi-final'
    WHEN 'final' THEN 'Final'
    ELSE v_stage
  END;

  FOREACH v_club IN ARRAY ARRAY[v_fixture.home_club_short_name, v_fixture.away_club_short_name]
  LOOP
    SELECT amount INTO v_amount
    FROM public.competition_cup_prize_config
    WHERE season_id = v_fixture.season_id
      AND cup_code = v_fixture.cup_code
      AND stage = 'appearance';

    IF v_amount IS NOT NULL AND v_amount > 0 THEN
      PERFORM public.competition_cup_credit_round_prize(
        p_fixture_id,
        v_club,
        'appearance',
        v_amount,
        format('%s appearance — %s', v_cup_label, public.competition_cup_fixture_label(v_fixture)),
        jsonb_build_object('cup_code', v_fixture.cup_code, 'stage', 'appearance')
      );
    END IF;
  END LOOP;

  SELECT amount INTO v_amount
  FROM public.competition_cup_prize_config
  WHERE season_id = v_fixture.season_id
    AND cup_code = v_fixture.cup_code
    AND stage = v_stage;

  IF v_amount IS NOT NULL AND v_amount > 0 THEN
    FOREACH v_club IN ARRAY ARRAY[v_fixture.home_club_short_name, v_fixture.away_club_short_name]
    LOOP
      PERFORM public.competition_cup_credit_round_prize(
        p_fixture_id,
        v_club,
        v_stage,
        v_amount,
        format('%s %s — %s', v_cup_label, v_stage_label, public.competition_cup_fixture_label(v_fixture)),
        jsonb_build_object('cup_code', v_fixture.cup_code, 'stage', v_stage)
      );
    END LOOP;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_backfill_cup_fixture_prizes(
  p_gpsl_month text DEFAULT NULL,
  p_cup_code text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_month text := nullif(lower(btrim(coalesce(p_gpsl_month, ''))), '');
  v_cup text := nullif(lower(btrim(coalesce(p_cup_code, ''))), '');
  v_fixture record;
  v_paid_before int;
  v_paid_after int;
  v_processed int := 0;
  v_credited int := 0;
  v_skipped_no_config int := 0;
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
      AND (v_month IS NULL OR f.gpsl_month = v_month)
      AND (v_cup IS NULL OR f.cup_code = v_cup)
    ORDER BY f.gpsl_month, f.cup_code, f.cup_round, f.id
  LOOP
    v_processed := v_processed + 1;

    SELECT count(*)::int
    INTO v_paid_before
    FROM public.competition_cup_prize_paid p
    WHERE p.fixture_id = v_fixture.id;

    IF NOT EXISTS (
      SELECT 1
      FROM public.competition_cup_prize_config c
      WHERE c.season_id = v_fixture.season_id
        AND c.cup_code = v_fixture.cup_code
        AND c.stage = public.competition_cup_round_stage(
          v_fixture.cup_code,
          v_fixture.cup_round,
          (
            SELECT max(round_no)
            FROM public.competition_cup_bracket_nodes n
            WHERE n.season_id = v_fixture.season_id
              AND n.cup_code = v_fixture.cup_code
          )
        )
        AND c.amount > 0
    ) THEN
      v_skipped_no_config := v_skipped_no_config + 1;
      CONTINUE;
    END IF;

    PERFORM public.competition_pay_cup_fixture_prizes(v_fixture.id);

    SELECT count(*)::int
    INTO v_paid_after
    FROM public.competition_cup_prize_paid p
    WHERE p.fixture_id = v_fixture.id;

    IF v_paid_after > v_paid_before THEN
      v_credited := v_credited + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'gpsl_month', v_month,
    'cup_code', v_cup,
    'fixtures_processed', v_processed,
    'fixtures_newly_credited', v_credited,
    'fixtures_skipped_no_config', v_skipped_no_config
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_backfill_cup_fixture_prizes(text, text, bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
