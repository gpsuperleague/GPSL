-- =============================================================================
-- Central Bank loan credit check
--
-- Reject new loans when a club has been overdrawn (negative balance) in
-- 2 or more seasons (archived closing balances + current live balance).
-- Bank manager declines with an unfavourable creditworthiness report.
--
-- Run in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_loan_negative_season_count(p_club text)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(coalesce(p_club, ''));
  v_count int := 0;
  v_current_id bigint;
  v_live numeric;
  v_archived_current boolean := false;
BEGIN
  IF v_club = '' THEN
    RETURN 0;
  END IF;

  SELECT count(*)::int
  INTO v_count
  FROM public.competition_club_finance_season_archive a
  WHERE a.club_short_name = v_club
    AND a.closing_balance < -0.005;

  SELECT s.id
  INTO v_current_id
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_current_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.competition_club_finance_season_archive a
      WHERE a.club_short_name = v_club
        AND a.season_id = v_current_id
    )
    INTO v_archived_current;

    IF NOT v_archived_current THEN
      SELECT coalesce(f.balance, 0)
      INTO v_live
      FROM public."Club_Finances" f
      WHERE f.club_name = v_club;

      IF coalesce(v_live, 0) < -0.005 THEN
        v_count := v_count + 1;
      END IF;
    END IF;
  END IF;

  RETURN coalesce(v_count, 0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_loan_credit_check(p_club text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := coalesce(nullif(btrim(p_club), ''), public.my_club_shortname());
  v_neg int;
  v_ok boolean;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'negative_seasons', 0,
      'message', 'No club linked to your account.'
    );
  END IF;

  IF p_club IS NOT NULL
     AND btrim(p_club) <> ''
     AND btrim(p_club) IS DISTINCT FROM public.my_club_shortname()
     AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not your club';
  END IF;

  v_neg := public.club_loan_negative_season_count(v_club);
  v_ok := v_neg < 2;

  IF v_ok THEN
    RETURN jsonb_build_object(
      'ok', true,
      'negative_seasons', v_neg,
      'message', NULL
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', false,
    'negative_seasons', v_neg,
    'message',
      'Application declined. The bank manager checked the club''s creditworthiness and an unfavourable report was received. Loans are not available while the club has been overdrawn for two seasons.'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_loan_negative_season_count(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_credit_check(text) TO authenticated;

-- Full take-loan with credit check (keeps current schedule / interest behaviour)
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
    RAISE EXCEPTION 'Maximum per drawdown is %', v_bank.loan_max_drawdown;
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
