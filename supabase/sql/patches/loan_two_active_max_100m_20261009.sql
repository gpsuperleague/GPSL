-- =============================================================================
-- Central Bank loans: up to 2 active loans at once, ₿100M owed in total
-- =============================================================================
-- Replaces "one loan per season (even if repaid), max ₿50M per loan".
--   • A club can hold at most 2 active (unpaid) loans at any time. Once one is
--     paid off it can take another.
--   • Total outstanding principal across its loans stays <= ₿100M
--     (repayments free up room). A single loan can be up to ₿100M.
--   • Credit check, minimum drawdown, 20-month term and rates are unchanged.
--
-- club_loan_taken_this_season keeps its name (the bank page calls it) but now
-- means "loan limit reached" = 2 active loans.
--
-- Safe re-run.
-- =============================================================================

UPDATE public.gpsl_bank_account
SET loan_max_drawdown = 100000000,
    loan_max_outstanding_per_club = 100000000,
    updated_at = now()
WHERE id = 1;

CREATE OR REPLACE FUNCTION public.club_loan_max_active()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 2 $$;

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
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RETURN false;
  END IF;

  RETURN (
    SELECT count(*) FROM public.club_loans l
    WHERE l.club_short_name = v_club AND l.status = 'active'
  ) >= public.club_loan_max_active();
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
  v_active int;
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

  IF to_regprocedure('public.club_loan_credit_check(text)') IS NOT NULL THEN
    v_credit := public.club_loan_credit_check(v_club);
    IF NOT coalesce((v_credit->>'ok')::boolean, false) THEN
      RAISE EXCEPTION '%', coalesce(
        v_credit->>'message',
        'Application declined. Unfavourable creditworthiness report.'
      );
    END IF;
  END IF;

  v_amount := round(coalesce(p_amount, 0)::numeric, 2);
  IF v_amount <= 0 THEN
    RAISE EXCEPTION 'Loan amount must be positive';
  END IF;

  IF to_regprocedure('public.competition_finances_current_season_id()') IS NOT NULL THEN
    v_season_id := public.competition_finances_current_season_id();
  END IF;

  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
      AND status IN ('active', 'preseason')
    ORDER BY CASE status WHEN 'active' THEN 0 ELSE 1 END, id DESC
    LIMIT 1;
  END IF;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No active competition season';
  END IF;

  v_drawdown_month := public.club_loan_normalize_drawdown_month(
    public.competition_active_gpsl_month(v_season_id, now())
  );

  -- Bank row lock serialises drawdowns, so the checks below can't be raced
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

  SELECT count(*)::int INTO v_active
  FROM public.club_loans l
  WHERE l.club_short_name = v_club AND l.status = 'active';

  IF v_active >= public.club_loan_max_active() THEN
    RAISE EXCEPTION
      'Maximum % active loans. Pay off one of your loans before taking another.',
      public.club_loan_max_active();
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
      'interest_rate_pct', v_rate,
      'drawdown_gpsl_month', v_drawdown_month
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

-- Check
SELECT
  b.loan_min_drawdown,
  b.loan_max_drawdown                AS max_per_loan_should_be_100m,
  b.loan_max_outstanding_per_club    AS max_total_owed_should_be_100m,
  public.club_loan_max_active()      AS max_active_loans,
  (SELECT count(*) FROM (
     SELECT l.club_short_name FROM public.club_loans l
     WHERE l.status = 'active'
     GROUP BY l.club_short_name HAVING count(*) >= 2) x) AS clubs_already_at_2_loans
FROM public.gpsl_bank_account b
WHERE b.id = 1;
