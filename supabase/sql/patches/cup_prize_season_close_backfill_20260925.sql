-- =============================================================================
-- Cup prize money: diagnose + repair + backfill (end of test season)
--
-- Why clubs show ₿0 under "Cup prize money":
--   1) competition_cup_prize_config empty / amount=0 when ties were confirmed
--      → pay is a silent no-op (most common for a whole season of zeros)
--   2) prize_cup missing from ledger entry_type CHECK (same class as gov subsidies)
--      → admin sim/deploy swallows the raise → fixtures played, no credits
--   3) Stale competition_pay_cup_fixture_prizes (from competition_cup_schedule.sql)
--      → posts entry_type 'prize' (not prize_cup) and can hard-error on paid INSERT
--      → finance UI "Cup prize money" only sums prize_cup → shows 0
--
-- This patch:
--   A) Ensures prize_cup is allowed on the ledger
--   B) Reinstalls modern pay (both clubs per round; winner/runner_up finals; r32/r16)
--   C) Remaps legacy cup ledger rows prize → prize_cup
--   D) Reinstalls improved admin backfill RPC
--   E) Prints diagnose NOTICEs + runs backfill for the current season
--
-- BEFORE RUNNING: set amounts in Admin → Cup Prize Money (or leave blank and
-- backfill will only credit cups that already have amount > 0).
-- Safe to re-run (idempotent paid table).
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- A) Ledger allow-list
-- ---------------------------------------------------------------------------
DO $ledger$
DECLARE
  v_types text[];
  v_sql text;
BEGIN
  IF to_regprocedure('public.gpsl_ledger_ensure_entry_types(text[])') IS NOT NULL THEN
    PERFORM public.gpsl_ledger_ensure_entry_types(ARRAY['prize_cup', 'prize']);
    RETURN;
  END IF;

  -- Fallback: rebuild CHECK from live types ∪ known set (includes prize_cup)
  SELECT array_agg(DISTINCT t ORDER BY t)
  INTO v_types
  FROM (
    SELECT unnest(ARRAY[
      'prize', 'prize_league', 'prize_cup', 'prize_challenge', 'tv_revenue',
      'gate_receipts', 'gate_cup_share', 'adjustment', 'wage_squad'
    ]) AS t
    UNION
    SELECT DISTINCT entry_type
    FROM public.competition_finance_ledger
    WHERE entry_type IS NOT NULL
  ) s;

  IF v_types IS NULL OR cardinality(v_types) = 0 THEN
    v_types := ARRAY['prize_cup'];
  END IF;

  ALTER TABLE public.competition_finance_ledger
    DROP CONSTRAINT IF EXISTS competition_finance_ledger_entry_type_check;

  v_sql := format(
    'ALTER TABLE public.competition_finance_ledger
       ADD CONSTRAINT competition_finance_ledger_entry_type_check
       CHECK (entry_type = ANY (%L::text[]))',
    v_types
  );
  EXECUTE v_sql;
END;
$ledger$;

-- ---------------------------------------------------------------------------
-- B) Stage label helper (needed by pay / award)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_cup_prize_stage_label(p_stage text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(coalesce(p_stage, ''))
    WHEN 'appearance' THEN 'Appearance'
    WHEN 'r1' THEN 'Last 64 / Round 1'
    WHEN 'r2' THEN 'Last 16 / Round 2'
    WHEN 'r32' THEN 'Last 32'
    WHEN 'r16' THEN 'Last 16'
    WHEN 'qf' THEN 'Quarter-final'
    WHEN 'sf' THEN 'Semi-final'
    WHEN 'final' THEN 'Final'
    WHEN 'winner' THEN 'Winner'
    WHEN 'runner_up' THEN 'Runner-up'
    ELSE coalesce(p_stage, '')
  END;
$$;

-- Modern pay: prize_cup via competition_cup_credit_round_prize
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
  v_winner_amt numeric;
  v_runner_amt numeric;
  v_club text;
  v_winner text;
  v_loser text;
  v_cup_label text;
  v_stage_label text;
  v_has_result_prize boolean := false;
BEGIN
  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id AND competition_type = 'cup';

  IF NOT FOUND THEN
    RETURN;
  END IF;

  -- Level / undecided draw with no pens → nothing to pay yet
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
  v_stage_label := public.competition_cup_prize_stage_label(v_stage);

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

  IF v_stage = 'final' THEN
    IF coalesce(btrim(v_fixture.cup_pen_winner_club_short_name), '') <> '' THEN
      v_winner := btrim(v_fixture.cup_pen_winner_club_short_name);
    ELSIF v_fixture.home_goals > v_fixture.away_goals THEN
      v_winner := v_fixture.home_club_short_name;
    ELSIF v_fixture.away_goals > v_fixture.home_goals THEN
      v_winner := v_fixture.away_club_short_name;
    ELSE
      RETURN;
    END IF;

    IF v_winner = v_fixture.home_club_short_name THEN
      v_loser := v_fixture.away_club_short_name;
    ELSE
      v_loser := v_fixture.home_club_short_name;
    END IF;

    SELECT amount INTO v_winner_amt
    FROM public.competition_cup_prize_config
    WHERE season_id = v_fixture.season_id
      AND cup_code = v_fixture.cup_code
      AND stage = 'winner';

    SELECT amount INTO v_runner_amt
    FROM public.competition_cup_prize_config
    WHERE season_id = v_fixture.season_id
      AND cup_code = v_fixture.cup_code
      AND stage = 'runner_up';

    IF v_winner_amt IS NOT NULL AND v_winner_amt > 0 THEN
      v_has_result_prize := true;
      PERFORM public.competition_cup_credit_round_prize(
        p_fixture_id,
        v_winner,
        'winner',
        v_winner_amt,
        format('%s Winner — %s', v_cup_label, public.competition_cup_fixture_label(v_fixture)),
        jsonb_build_object('cup_code', v_fixture.cup_code, 'stage', 'winner')
      );
    END IF;

    IF v_runner_amt IS NOT NULL AND v_runner_amt > 0 THEN
      v_has_result_prize := true;
      PERFORM public.competition_cup_credit_round_prize(
        p_fixture_id,
        v_loser,
        'runner_up',
        v_runner_amt,
        format('%s Runner-up — %s', v_cup_label, public.competition_cup_fixture_label(v_fixture)),
        jsonb_build_object('cup_code', v_fixture.cup_code, 'stage', 'runner_up')
      );
    END IF;

    IF NOT v_has_result_prize THEN
      SELECT amount INTO v_amount
      FROM public.competition_cup_prize_config
      WHERE season_id = v_fixture.season_id
        AND cup_code = v_fixture.cup_code
        AND stage = 'final';

      IF v_amount IS NOT NULL AND v_amount > 0 THEN
        FOREACH v_club IN ARRAY ARRAY[v_fixture.home_club_short_name, v_fixture.away_club_short_name]
        LOOP
          PERFORM public.competition_cup_credit_round_prize(
            p_fixture_id,
            v_club,
            'final',
            v_amount,
            format('%s Final — %s', v_cup_label, public.competition_cup_fixture_label(v_fixture)),
            jsonb_build_object('cup_code', v_fixture.cup_code, 'stage', 'final')
          );
        END LOOP;
      END IF;
    END IF;

    RETURN;
  END IF;

  -- Non-final rounds: same amount to both clubs
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

GRANT EXECUTE ON FUNCTION public.competition_pay_cup_fixture_prizes(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- C) Remap legacy cup 'prize' ledger rows → prize_cup (finances UI)
-- ---------------------------------------------------------------------------
UPDATE public.competition_finance_ledger l
SET entry_type = 'prize_cup'
WHERE l.entry_type = 'prize'
  AND (
    (l.metadata ? 'cup_code')
    OR coalesce(l.description, '') ~* '(appearance|round|winner|runner|champion|cup|bowl|plate|shield|super.?8)'
  );

-- ---------------------------------------------------------------------------
-- D) Improved backfill RPC
-- ---------------------------------------------------------------------------
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
  v_errors int := 0;
  v_stage text;
  v_max_round int;
  v_has_config boolean;
  v_err text;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
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
      AND f.home_goals IS NOT NULL
      AND f.away_goals IS NOT NULL
      AND (v_month IS NULL OR lower(f.gpsl_month) = v_month)
      AND (v_cup IS NULL OR lower(f.cup_code) = v_cup)
      AND lower(coalesce(f.cup_code, '')) NOT LIKE 'po\_%' ESCAPE '\'
    ORDER BY f.gpsl_month, f.cup_code, f.cup_round, coalesce(f.cup_leg, 1), f.id
  LOOP
    v_processed := v_processed + 1;

    SELECT count(*)::int
    INTO v_paid_before
    FROM public.competition_cup_prize_paid p
    WHERE p.fixture_id = v_fixture.id;

    SELECT max(n.round_no) INTO v_max_round
    FROM public.competition_cup_bracket_nodes n
    WHERE n.season_id = v_fixture.season_id
      AND n.cup_code = v_fixture.cup_code;

    v_stage := public.competition_cup_round_stage(
      v_fixture.cup_code,
      v_fixture.cup_round,
      coalesce(v_max_round, v_fixture.cup_round)
    );

    SELECT EXISTS (
      SELECT 1
      FROM public.competition_cup_prize_config c
      WHERE c.season_id = v_fixture.season_id
        AND c.cup_code = v_fixture.cup_code
        AND c.amount > 0
        AND (
          c.stage = 'appearance'
          OR c.stage = v_stage
          OR (
            v_stage = 'final'
            AND c.stage IN ('final', 'winner', 'runner_up')
          )
        )
    )
    INTO v_has_config;

    IF NOT coalesce(v_has_config, false) THEN
      v_skipped_no_config := v_skipped_no_config + 1;
      CONTINUE;
    END IF;

    BEGIN
      PERFORM public.competition_pay_cup_fixture_prizes(v_fixture.id);
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors + 1;
      v_err := SQLERRM;
      RAISE WARNING 'cup prize backfill fixture % failed: %', v_fixture.id, v_err;
      CONTINUE;
    END;

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
    'fixtures_skipped_no_config', v_skipped_no_config,
    'fixtures_errors', v_errors
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_backfill_cup_fixture_prizes(text, text, bigint)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- E) Diagnose + backfill current season
-- ---------------------------------------------------------------------------
DO $run$
DECLARE
  v_sid bigint;
  v_label text;
  v_cfg_positive int;
  v_cfg_total int;
  v_played int;
  v_paid_rows int;
  v_paid_sum numeric;
  v_ledger_cup int;
  v_ledger_cup_sum numeric;
  v_ledger_legacy int;
  v_result jsonb;
BEGIN
  SELECT id, coalesce(label, id::text)
  INTO v_sid, v_label
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_sid IS NULL THEN
    RAISE NOTICE 'cup_prize_season_close: no current season — skip backfill';
    RETURN;
  END IF;

  SELECT count(*) FILTER (WHERE amount > 0), count(*)
  INTO v_cfg_positive, v_cfg_total
  FROM public.competition_cup_prize_config
  WHERE season_id = v_sid;

  SELECT count(*)
  INTO v_played
  FROM public.competition_fixtures
  WHERE season_id = v_sid
    AND competition_type = 'cup'
    AND status = 'played'
    AND lower(coalesce(cup_code, '')) NOT LIKE 'po\_%' ESCAPE '\';

  SELECT count(*), coalesce(sum(amount), 0)
  INTO v_paid_rows, v_paid_sum
  FROM public.competition_cup_prize_paid p
  JOIN public.competition_fixtures f ON f.id = p.fixture_id
  WHERE f.season_id = v_sid;

  SELECT count(*), coalesce(sum(amount), 0)
  INTO v_ledger_cup, v_ledger_cup_sum
  FROM public.competition_finance_ledger
  WHERE season_id = v_sid AND entry_type = 'prize_cup';

  SELECT count(*)
  INTO v_ledger_legacy
  FROM public.competition_finance_ledger
  WHERE season_id = v_sid
    AND entry_type = 'prize'
    AND metadata ? 'cup_code';

  RAISE NOTICE
    'cup_prize_season_close diagnose season=% (%) cfg_rows=% cfg_amount_gt0=% played_cup_ties=% paid_rows=% paid_sum=% ledger_prize_cup_rows=% ledger_prize_cup_sum=% leftover_legacy_prize_cupmeta=%',
    v_sid, v_label, v_cfg_total, v_cfg_positive, v_played,
    v_paid_rows, v_paid_sum, v_ledger_cup, v_ledger_cup_sum, v_ledger_legacy;

  IF v_cfg_positive = 0 THEN
    RAISE NOTICE
      'cup_prize_season_close: NO positive prize amounts for season %. Set Admin → Cup Prize Money, then re-run: SELECT competition_admin_backfill_cup_fixture_prizes(NULL, NULL, %);',
      v_sid, v_sid;
  ELSE
    v_result := public.competition_admin_backfill_cup_fixture_prizes(NULL, NULL, v_sid);
    RAISE NOTICE 'cup_prize_season_close backfill result: %', v_result;
  END IF;
END;
$run$;

NOTIFY pgrst, 'reload schema';

COMMIT;
