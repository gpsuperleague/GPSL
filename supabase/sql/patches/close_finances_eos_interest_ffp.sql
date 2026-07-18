-- =============================================================================
-- Close Finances: EOS balance interest, debt interest, and FFP.
-- Wires into competition_admin_close_finances (wages → debt → FFP → credit interest).
--
-- Defaults (gpsl_bank_account):
--   Positive balance interest: 0.5%
--   Debt interest: policy_interest_rate_pct (usually 5%) on overdrawn balances
--   FFP: flat ₿10M if balance ≤ −₿100M (threshold / fine configurable)
--
-- Idempotent via competition_season_charge_paid. Safe to re-run.
-- =============================================================================

ALTER TABLE public.gpsl_bank_account
  ADD COLUMN IF NOT EXISTS eos_balance_interest_pct numeric(5, 2) NOT NULL DEFAULT 0.50,
  ADD COLUMN IF NOT EXISTS eos_debt_interest_pct numeric(5, 2),
  ADD COLUMN IF NOT EXISTS eos_ffp_debt_threshold numeric(14, 2) NOT NULL DEFAULT 100000000,
  ADD COLUMN IF NOT EXISTS eos_ffp_flat_fine numeric(14, 2) NOT NULL DEFAULT 10000000;

COMMENT ON COLUMN public.gpsl_bank_account.eos_balance_interest_pct IS
  'EOS credit %% on positive Club_Finances.balance (Close Finances).';
COMMENT ON COLUMN public.gpsl_bank_account.eos_debt_interest_pct IS
  'EOS debit %% on negative balances. NULL = use policy_interest_rate_pct.';
COMMENT ON COLUMN public.gpsl_bank_account.eos_ffp_debt_threshold IS
  'FFP triggers when balance <= -threshold (default ₿100M).';
COMMENT ON COLUMN public.gpsl_bank_account.eos_ffp_flat_fine IS
  'Flat FFP fine charged to central bank when threshold breached.';

ALTER TABLE public.competition_season_charge_paid
  DROP CONSTRAINT IF EXISTS competition_season_charge_paid_charge_type_check;

ALTER TABLE public.competition_season_charge_paid
  ADD CONSTRAINT competition_season_charge_paid_charge_type_check
  CHECK (
    charge_type IN (
      'wage_squad',
      'wage_renewal_34plus',
      'wage_star_tax',
      'staff_manager_salary',
      'gov_emergency_tax',
      'gov_income_tax',
      'eos_ffp_charge',
      'eos_debt_interest',
      'eos_balance_interest'
    )
  );

-- ---------------------------------------------------------------------------
-- 0.5% (configurable) credit on positive balances — season clubs only
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_post_eos_balance_interest(p_season_id bigint)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_interest numeric;
  v_paid int := 0;
  v_rate numeric;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN 0;
  END IF;

  SELECT greatest(coalesce(b.eos_balance_interest_pct, 0.50), 0) / 100.0
  INTO v_rate
  FROM public.gpsl_bank_account b
  WHERE b.id = 1;

  v_rate := coalesce(v_rate, 0.005);

  FOR v_club IN
    SELECT f.club_name AS club_short_name, f.balance
    FROM public."Club_Finances" f
    JOIN public.competition_club_seasons ccs
      ON ccs.club_short_name = f.club_name
     AND ccs.season_id = p_season_id
     AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
    WHERE f.balance > 0
      AND f.club_name <> 'FOREIGN'
  LOOP
    IF EXISTS (
      SELECT 1 FROM public.competition_season_charge_paid
      WHERE season_id = p_season_id
        AND club_short_name = v_club.club_short_name
        AND charge_type = 'eos_balance_interest'
    ) THEN
      CONTINUE;
    END IF;

    v_interest := round(v_club.balance * v_rate, 0);
    IF v_interest <= 0 THEN
      CONTINUE;
    END IF;

    PERFORM public.post_club_ledger(
      v_club.club_short_name,
      'eos_balance_interest',
      v_interest,
      format(
        'End of season balance interest — %s%% on ₿%s',
        to_char(v_rate * 100, 'FM999990.###'),
        to_char(v_club.balance, 'FM999,999,999,999')
      ),
      jsonb_build_object(
        'balance_snapshot', v_club.balance,
        'rate_pct', v_rate * 100
      ),
      p_season_id,
      NULL,
      true,
      true
    );

    INSERT INTO public.competition_season_charge_paid (
      season_id, club_short_name, charge_type, amount, metadata
    )
    VALUES (
      p_season_id,
      v_club.club_short_name,
      'eos_balance_interest',
      v_interest,
      jsonb_build_object(
        'balance_snapshot', v_club.balance,
        'rate_pct', v_rate * 100
      )
    );

    v_paid := v_paid + 1;
  END LOOP;

  RETURN v_paid;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Interest on overdrawn (negative) balances
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_post_eos_debt_interest(p_season_id bigint)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_interest numeric;
  v_paid int := 0;
  v_rate_pct numeric;
  v_debt numeric;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN 0;
  END IF;

  SELECT coalesce(nullif(b.eos_debt_interest_pct, 0), b.policy_interest_rate_pct, 5.00)
  INTO v_rate_pct
  FROM public.gpsl_bank_account b
  WHERE b.id = 1;

  v_rate_pct := greatest(coalesce(v_rate_pct, 5.00), 0);

  FOR v_club IN
    SELECT f.club_name AS club_short_name, f.balance
    FROM public."Club_Finances" f
    JOIN public.competition_club_seasons ccs
      ON ccs.club_short_name = f.club_name
     AND ccs.season_id = p_season_id
     AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
    WHERE f.balance < 0
      AND f.club_name <> 'FOREIGN'
  LOOP
    IF EXISTS (
      SELECT 1 FROM public.competition_season_charge_paid
      WHERE season_id = p_season_id
        AND club_short_name = v_club.club_short_name
        AND charge_type = 'eos_debt_interest'
    ) THEN
      CONTINUE;
    END IF;

    v_debt := abs(v_club.balance);
    v_interest := round(v_debt * v_rate_pct / 100.0, 0);
    IF v_interest <= 0 THEN
      CONTINUE;
    END IF;

    IF public.competition_post_club_charge(
      p_season_id,
      v_club.club_short_name,
      'eos_debt_interest',
      v_interest,
      format(
        'End of season debt interest — %s%% on overdraft ₿%s',
        to_char(v_rate_pct, 'FM999990.###'),
        to_char(v_debt, 'FM999,999,999,999')
      ),
      jsonb_build_object(
        'balance_snapshot', v_club.balance,
        'rate_pct', v_rate_pct
      )
    ) THEN
      v_paid := v_paid + 1;
    END IF;
  END LOOP;

  RETURN v_paid;
END;
$function$;

-- ---------------------------------------------------------------------------
-- FFP: flat fine when balance ≤ −threshold (default −₿100M)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_post_eos_ffp_charges(p_season_id bigint)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_paid int := 0;
  v_threshold numeric;
  v_fine numeric;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN 0;
  END IF;

  SELECT
    greatest(coalesce(b.eos_ffp_debt_threshold, 100000000), 0),
    greatest(coalesce(b.eos_ffp_flat_fine, 10000000), 0)
  INTO v_threshold, v_fine
  FROM public.gpsl_bank_account b
  WHERE b.id = 1;

  v_threshold := coalesce(v_threshold, 100000000);
  v_fine := coalesce(v_fine, 10000000);

  IF v_fine <= 0 THEN
    RETURN 0;
  END IF;

  FOR v_club IN
    SELECT f.club_name AS club_short_name, f.balance
    FROM public."Club_Finances" f
    JOIN public.competition_club_seasons ccs
      ON ccs.club_short_name = f.club_name
     AND ccs.season_id = p_season_id
     AND ccs.division IN ('superleague', 'championship_a', 'championship_b')
    WHERE f.balance <= -v_threshold
      AND f.club_name <> 'FOREIGN'
  LOOP
    IF EXISTS (
      SELECT 1 FROM public.competition_season_charge_paid
      WHERE season_id = p_season_id
        AND club_short_name = v_club.club_short_name
        AND charge_type = 'eos_ffp_charge'
    ) THEN
      CONTINUE;
    END IF;

    IF public.competition_post_club_charge(
      p_season_id,
      v_club.club_short_name,
      'eos_ffp_charge',
      v_fine,
      format(
        'FFP charge — balance ₿%s at/below −₿%s threshold',
        to_char(v_club.balance, 'FM999,999,999,999'),
        to_char(v_threshold, 'FM999,999,999,999')
      ),
      jsonb_build_object(
        'balance_snapshot', v_club.balance,
        'threshold', v_threshold,
        'flat_fine', v_fine
      )
    ) THEN
      v_paid := v_paid + 1;
    END IF;
  END LOOP;

  RETURN v_paid;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Close Finances orchestrator (idempotent)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.competition_admin_close_finances(
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_wages jsonb;
  v_debt int := 0;
  v_ffp int := 0;
  v_credit int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  ELSE
    v_season_id := p_season_id;
  END IF;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current season';
  END IF;

  -- 1) Season wage bills (players, manager salary, 34+, star tax)
  v_wages := public.competition_admin_post_season_wage_bills(v_season_id);

  -- 2) Debt interest on overdrawn accounts (after wages)
  v_debt := public.competition_post_eos_debt_interest(v_season_id);

  -- 3) FFP on clubs at/below −threshold (after debt interest)
  v_ffp := public.competition_post_eos_ffp_charges(v_season_id);

  -- 4) Credit interest on positive balances
  v_credit := public.competition_post_eos_balance_interest(v_season_id);

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'wages', v_wages,
    'debt_interest_clubs', v_debt,
    'ffp_clubs', v_ffp,
    'balance_interest_clubs', v_credit
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_post_eos_balance_interest(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_post_eos_debt_interest(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_post_eos_ffp_charges(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_close_finances(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
