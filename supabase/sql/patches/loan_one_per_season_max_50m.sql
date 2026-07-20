-- =============================================================================
-- One Central Bank loan per club per season (max ₿50M per drawdown).
-- A repaid / closed loan still counts — only one drawdown per season.
--
-- Run in Supabase SQL Editor. Safe re-run.
-- =============================================================================

-- Keep per-drawdown cap at ₿50M (explicit)
UPDATE public.gpsl_bank_account
SET loan_max_drawdown = 50000000,
    updated_at = now()
WHERE id = 1
  AND coalesce(loan_max_drawdown, 0) <> 50000000;

CREATE OR REPLACE FUNCTION public.club_loan_taken_this_season(
  p_club text DEFAULT NULL,
  p_season_id bigint DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := coalesce(nullif(btrim(p_club), ''), public.my_club_shortname());
  v_season_id bigint := p_season_id;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RETURN false;
  END IF;

  IF v_season_id IS NULL THEN
    SELECT s.id INTO v_season_id
    FROM public.competition_seasons s
    WHERE s.is_current = true
    ORDER BY s.id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.club_loans l
    WHERE l.club_short_name = v_club
      AND l.season_id = v_season_id
      -- Any status counts (active, paid, etc.) — one drawdown per season only
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_loan_taken_this_season(text, bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.club_take_loan(p_amount numeric)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_amount numeric;
  v_season_id bigint;
  v_bank record;
  v_outstanding numeric;
  v_loan_id bigint;
  v_ledger_id bigint;
  v_desc text;
  v_drawdown_month text;
  v_months smallint := 20;
  v_rate numeric;
  v_credit jsonb;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  v_credit := public.club_loan_credit_check(v_club);
  IF NOT coalesce((v_credit->>'ok')::boolean, false) THEN
    RAISE EXCEPTION '%', coalesce(
      v_credit->>'message',
      'Application declined. Unfavourable creditworthiness report.'
    );
  END IF;

  v_amount := round(coalesce(p_amount, 0)::numeric, 2);
  IF v_amount <= 0 THEN
    RAISE EXCEPTION 'Loan amount must be positive';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No active competition season';
  END IF;

  IF public.club_loan_taken_this_season(v_club, v_season_id) THEN
    RAISE EXCEPTION
      'Maximum one loan per season. Your club has already taken a loan this season (repaying it does not allow another).';
  END IF;

  v_drawdown_month := public.competition_active_gpsl_month(v_season_id, now());
  IF v_drawdown_month IS NULL THEN
    v_drawdown_month := 'august';
  END IF;

  SELECT
    loans_enabled,
    loan_min_drawdown,
    loan_max_drawdown,
    loan_max_outstanding_per_club,
    policy_interest_rate_pct
  INTO v_bank
  FROM public.gpsl_bank_account
  WHERE id = 1
  FOR UPDATE;

  IF NOT coalesce(v_bank.loans_enabled, false) THEN
    RAISE EXCEPTION 'Bank loans are currently disabled';
  END IF;

  IF v_amount < v_bank.loan_min_drawdown THEN
    RAISE EXCEPTION 'Minimum loan is %', v_bank.loan_min_drawdown;
  END IF;

  IF v_amount > v_bank.loan_max_drawdown THEN
    RAISE EXCEPTION 'Maximum per loan is %', v_bank.loan_max_drawdown;
  END IF;

  v_outstanding := public.club_loan_outstanding_for(v_club);

  IF v_outstanding + v_amount > v_bank.loan_max_outstanding_per_club THEN
    RAISE EXCEPTION 'Would exceed max outstanding loan (%) for your club',
      v_bank.loan_max_outstanding_per_club;
  END IF;

  v_rate := v_bank.policy_interest_rate_pct;

  INSERT INTO public.club_loans (
    club_short_name,
    season_id,
    principal_drawn,
    outstanding_principal,
    interest_rate_pct,
    status,
    repayment_months,
    drawdown_gpsl_month,
    installments_paid
  )
  VALUES (
    v_club,
    v_season_id,
    v_amount,
    v_amount,
    v_rate,
    'active',
    v_months,
    v_drawdown_month,
    0
  )
  RETURNING id INTO v_loan_id;

  PERFORM public.club_loan_generate_installments(
    v_loan_id,
    v_amount,
    v_season_id,
    v_drawdown_month,
    v_months,
    v_rate
  );

  v_desc := format(
    'Central bank loan drawdown (loan #%s) — %s GPSL months from %s at %s%% p.a.',
    v_loan_id,
    v_months,
    public.competition_gpsl_month_label(v_drawdown_month),
    trim(to_char(v_rate, 'FM999990.00'))
  );

  v_ledger_id := public.post_club_ledger(
    v_club,
    'loan_drawdown',
    v_amount,
    v_desc,
    jsonb_build_object(
      'loan_id', v_loan_id,
      'repayment_months', v_months,
      'interest_rate_pct', v_rate
    ),
    v_season_id,
    NULL,
    true,
    true
  );

  UPDATE public.gpsl_bank_account
  SET loan_book_outstanding = loan_book_outstanding + v_amount,
      updated_at = now()
  WHERE id = 1;

  RETURN v_loan_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_take_loan(numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
