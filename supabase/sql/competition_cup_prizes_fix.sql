-- =============================================================================
-- GPSL — Cup prize money fix
-- Run once after competition_phase6_cups.sql (and competition_league_prizes.sql).
--
-- Changes:
--   • Round prize paid to BOTH clubs (same amount — not winner-only)
--   • Ledger entry_type prize_cup (not generic prize)
--   • Admin override: award round prize to one club (walkover / no-show)
--   • Stage names aligned with SQL: appearance, r1, r2, qf, sf, final
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Ledger: prize_cup (+ keep prize_league if already applied)
-- ---------------------------------------------------------------------------

ALTER TABLE public.competition_finance_ledger
  DROP CONSTRAINT IF EXISTS competition_finance_ledger_entry_type_check;

ALTER TABLE public.competition_finance_ledger
  ADD CONSTRAINT competition_finance_ledger_entry_type_check
  CHECK (
    entry_type IN (
      'gate_league_home',
      'gate_cup_share',
      'prize',
      'prize_league',
      'prize_cup',
      'adjustment',
      'admin_one_off_injection',
      'admin_purchase_payment',
      'transfer_sale',
      'transfer_purchase',
      'transfer_agent_fee',
      'transfer_foreign_sale',
      'transfer_overflow_release',
      'loan_drawdown',
      'loan_repayment_principal',
      'loan_interest_payment',
      'infra_maintenance',
      'infra_purchase',
      'infra_expansion',
      'infra_expansion_refund',
      'infra_expansion_penalty'
    )
  );

-- Reclassify historical cup lines posted as generic prize
UPDATE public.competition_finance_ledger
SET entry_type = 'prize_cup'
WHERE entry_type = 'prize'
  AND (
    metadata ? 'cup_code'
    OR description ILIKE '%appearance%'
    OR description ILIKE '%champion%'
    OR description ILIKE '% winner%'
    OR description ILIKE '%round 1%'
    OR description ILIKE '%quarter-final%'
    OR description ILIKE '%semi-final%'
    OR description ILIKE '%final%'
  );

-- Remove legacy admin UI stage names that never matched SQL payout logic
DELETE FROM public.competition_cup_prize_config
WHERE stage IN ('runner_up', 'semi', 'quarter', 'r16', 'r32', 'winner');

-- ---------------------------------------------------------------------------
-- Public read of cup prize config
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW public.competition_cup_prize_config_public
WITH (security_invoker = false)
AS
SELECT season_id, cup_code, stage, amount
FROM public.competition_cup_prize_config;

GRANT SELECT ON public.competition_cup_prize_config_public TO authenticated;
GRANT SELECT ON public.competition_cup_prize_config_public TO anon;

-- ---------------------------------------------------------------------------
-- Idempotent cup prize credit (one club + stage)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_cup_credit_round_prize(
  p_fixture_id bigint,
  p_club_short_name text,
  p_stage text,
  p_amount numeric,
  p_description text,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_club text := btrim(p_club_short_name);
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN false;
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id AND competition_type = 'cup';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cup fixture % not found', p_fixture_id;
  END IF;

  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  IF v_club NOT IN (v_fixture.home_club_short_name, v_fixture.away_club_short_name) THEN
    RAISE EXCEPTION 'Club % is not in fixture %', v_club, p_fixture_id;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.competition_cup_prize_paid
    WHERE fixture_id = p_fixture_id
      AND club_short_name = v_club
      AND stage = p_stage
  ) THEN
    RETURN false;
  END IF;

  PERFORM public.competition_credit_club_balance(v_club, p_amount);

  INSERT INTO public.competition_finance_ledger (
    season_id, fixture_id, club_short_name, entry_type, amount, description, metadata
  )
  VALUES (
    v_fixture.season_id,
    p_fixture_id,
    v_club,
    'prize_cup',
    p_amount,
    p_description,
    p_metadata
  );

  INSERT INTO public.competition_cup_prize_paid (fixture_id, club_short_name, stage, amount)
  VALUES (p_fixture_id, v_club, p_stage, p_amount);

  RETURN true;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Pay cup prizes: both teams receive round fee (+ optional appearance both)
-- ---------------------------------------------------------------------------

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

  IF v_fixture.home_goals IS NOT DISTINCT FROM v_fixture.away_goals THEN
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

  -- Optional appearance fee (both clubs)
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

  -- Round fee — same amount to BOTH clubs (playing in this round)
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

-- ---------------------------------------------------------------------------
-- Admin: set cup prize (validated stages)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_admin_set_cup_prize(
  p_season_id bigint,
  p_cup_code text,
  p_stage text,
  p_amount numeric
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_stage = 'winner' THEN
    RAISE EXCEPTION 'Stage winner is deprecated. Set the round fee under final (both clubs receive the same amount).';
  END IF;

  IF p_stage NOT IN ('appearance', 'r1', 'r2', 'qf', 'sf', 'final') THEN
    RAISE EXCEPTION 'Invalid stage %. Use: appearance, r1, r2, qf, sf, final', p_stage;
  END IF;

  IF p_cup_code NOT IN ('super8', 'plate', 'shield', 'spoon', 'league_cup') THEN
    RAISE EXCEPTION 'Invalid cup code';
  END IF;

  INSERT INTO public.competition_cup_prize_config (season_id, cup_code, stage, amount)
  VALUES (p_season_id, p_cup_code, p_stage, coalesce(p_amount, 0))
  ON CONFLICT (season_id, cup_code, stage)
  DO UPDATE SET amount = excluded.amount;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Admin override: award round prize to one club (walkover / no-show)
-- Does not require the match to be played or confirmed.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_admin_award_cup_round_prize(
  p_fixture_id bigint,
  p_club_short_name text,
  p_stage text DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
  v_max_round int;
  v_stage text;
  v_amount numeric;
  v_cup_label text;
  v_stage_label text;
  v_desc text;
  v_paid boolean;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id AND competition_type = 'cup';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cup fixture % not found', p_fixture_id;
  END IF;

  IF p_stage IS NOT NULL AND btrim(p_stage) <> '' THEN
    v_stage := btrim(p_stage);
  ELSE
    SELECT max(round_no) INTO v_max_round
    FROM public.competition_cup_bracket_nodes
    WHERE season_id = v_fixture.season_id AND cup_code = v_fixture.cup_code;

    v_stage := public.competition_cup_round_stage(
      v_fixture.cup_code,
      v_fixture.cup_round,
      coalesce(v_max_round, v_fixture.cup_round)
    );
  END IF;

  IF v_stage NOT IN ('appearance', 'r1', 'r2', 'qf', 'sf', 'final') THEN
    RAISE EXCEPTION 'Invalid stage %', v_stage;
  END IF;

  SELECT amount INTO v_amount
  FROM public.competition_cup_prize_config
  WHERE season_id = v_fixture.season_id
    AND cup_code = v_fixture.cup_code
    AND stage = v_stage;

  IF v_amount IS NULL OR v_amount <= 0 THEN
    RAISE EXCEPTION 'No prize configured for % / % / stage %',
      v_fixture.cup_code, v_fixture.season_id, v_stage;
  END IF;

  v_cup_label := upper(replace(coalesce(v_fixture.cup_code, 'cup'), '_', ' '));
  v_stage_label := CASE v_stage
    WHEN 'r1' THEN 'Round 1'
    WHEN 'r2' THEN 'Round 2'
    WHEN 'qf' THEN 'Quarter-final'
    WHEN 'sf' THEN 'Semi-final'
    WHEN 'final' THEN 'Final'
    WHEN 'appearance' THEN 'Appearance'
    ELSE v_stage
  END;

  v_desc := format('%s %s — %s (admin award)', v_cup_label, v_stage_label, public.competition_cup_fixture_label(v_fixture));
  IF p_note IS NOT NULL AND btrim(p_note) <> '' THEN
    v_desc := v_desc || ' — ' || btrim(p_note);
  END IF;

  v_paid := public.competition_cup_credit_round_prize(
    p_fixture_id,
    p_club_short_name,
    v_stage,
    v_amount,
    v_desc,
    jsonb_build_object(
      'cup_code', v_fixture.cup_code,
      'stage', v_stage,
      'admin_override', true,
      'note', p_note
    )
  );

  RETURN jsonb_build_object(
    'fixture_id', p_fixture_id,
    'club_short_name', p_club_short_name,
    'stage', v_stage,
    'amount', v_amount,
    'paid', v_paid
  );
END;
$function$;

-- Admin direct score entry must also pay cup prizes (was gates-only in phase 5)
CREATE OR REPLACE FUNCTION public.competition_admin_record_result(
  p_fixture_id bigint,
  p_home_goals smallint,
  p_away_goals smallint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_fixture public.competition_fixtures;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_home_goals IS NULL OR p_away_goals IS NULL OR p_home_goals < 0 OR p_away_goals < 0 THEN
    RAISE EXCEPTION 'Invalid score';
  END IF;

  SELECT * INTO v_fixture
  FROM public.competition_fixtures
  WHERE id = p_fixture_id
    AND competition_type IN ('league', 'cup');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture not found';
  END IF;

  UPDATE public.competition_fixtures
  SET home_goals = p_home_goals,
      away_goals = p_away_goals,
      status = 'played'
  WHERE id = p_fixture_id;

  PERFORM public.competition_settle_fixture_gates(p_fixture_id);

  IF v_fixture.competition_type = 'cup' THEN
    PERFORM public.competition_cup_on_fixture_played(p_fixture_id);
  ELSIF v_fixture.competition_type = 'league'
    AND EXISTS (
      SELECT 1
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND p.proname = 'competition_try_pay_league_division_prizes'
    ) THEN
    EXECUTE 'SELECT public.competition_try_pay_league_division_prizes($1, $2)'
    USING v_fixture.season_id, v_fixture.division;
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_admin_award_cup_round_prize(bigint, text, text, text) TO authenticated;
