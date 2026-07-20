-- =============================================================================
-- Hotfix: club_loan_apply_principal_payment used wrong Club_Finances columns
-- (cf."Balance" / cf."ShortName") → repay RPC failed with:
--   column cf.Balance does not exist
--
-- Correct columns: balance, club_name
-- Run in Supabase SQL Editor, then retry repay.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_loan_apply_principal_payment(
  p_loan_id bigint,
  p_amount numeric,
  p_description text DEFAULT NULL,
  p_installment_id bigint DEFAULT NULL
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_pay numeric;
  v_balance numeric;
  v_loan record;
  v_desc text;
  v_inst record;
  v_ledger_season bigint;
  v_due_season bigint;
BEGIN
  SELECT *
  INTO v_loan
  FROM public.club_loans
  WHERE id = p_loan_id
    AND status = 'active'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active loan not found';
  END IF;

  IF v_club IS NOT NULL AND v_club <> '' AND v_loan.club_short_name <> v_club THEN
    IF NOT public.is_gpsl_admin() THEN
      RAISE EXCEPTION 'Not your loan';
    END IF;
  END IF;

  v_pay := round(coalesce(p_amount, 0)::numeric, 2);
  IF v_pay <= 0 THEN
    RETURN 0;
  END IF;

  v_pay := least(v_pay, v_loan.outstanding_principal);
  IF v_pay <= 0 THEN
    RETURN 0;
  END IF;

  SELECT coalesce(cf.balance, 0)
  INTO v_balance
  FROM public."Club_Finances" cf
  WHERE cf.club_name = v_loan.club_short_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Club_Finances row missing';
  END IF;

  IF coalesce(v_balance, 0) < v_pay THEN
    RAISE EXCEPTION 'Insufficient balance to repay % (balance %)', v_pay, v_balance;
  END IF;

  v_due_season := NULL;
  IF p_installment_id IS NOT NULL THEN
    SELECT due_season_id INTO v_due_season
    FROM public.club_loan_installments
    WHERE id = p_installment_id
      AND loan_id = p_loan_id;
  END IF;

  v_ledger_season := v_due_season;
  IF v_ledger_season IS NULL THEN
    SELECT id INTO v_ledger_season
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
    v_ledger_season := coalesce(v_ledger_season, v_loan.season_id);
  END IF;

  v_desc := coalesce(
    nullif(btrim(p_description), ''),
    format('Loan principal repayment (loan #%s)', v_loan.id)
  );

  PERFORM public.post_club_ledger(
    v_loan.club_short_name,
    'loan_repayment_principal',
    -v_pay,
    v_desc,
    jsonb_build_object(
      'loan_id', v_loan.id,
      'installment_id', p_installment_id
    ),
    v_ledger_season,
    NULL,
    true,
    true
  );

  UPDATE public.club_loans
  SET outstanding_principal = outstanding_principal - v_pay,
      updated_at = now(),
      status = CASE
        WHEN outstanding_principal - v_pay <= 0.005 THEN 'paid'
        ELSE 'active'
      END,
      closed_at = CASE
        WHEN outstanding_principal - v_pay <= 0.005 THEN coalesce(closed_at, now())
        ELSE closed_at
      END
  WHERE id = p_loan_id;

  IF p_installment_id IS NOT NULL THEN
    UPDATE public.club_loan_installments
    SET paid_amount = paid_amount + v_pay,
        paid_at = CASE
          WHEN paid_amount + v_pay >= principal_due
            AND interest_paid >= coalesce(interest_due, 0) THEN now()
          ELSE paid_at
        END,
        status = CASE
          WHEN paid_amount + v_pay >= principal_due
            AND interest_paid >= coalesce(interest_due, 0) THEN 'paid'
          ELSE status
        END
    WHERE id = p_installment_id
      AND loan_id = p_loan_id;
  END IF;

  -- Early settle / final principal: waive remaining scheduled interest
  IF v_loan.outstanding_principal - v_pay <= 0.005 THEN
    UPDATE public.club_loan_installments
    SET status = 'skipped',
        interest_due = least(interest_due, interest_paid)
    WHERE loan_id = p_loan_id
      AND status = 'pending';
  END IF;

  UPDATE public.gpsl_bank_account
  SET loan_book_outstanding = greatest(0, loan_book_outstanding - v_pay),
      reserves = reserves + v_pay,
      updated_at = now()
  WHERE id = 1;

  RETURN v_pay;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_loan_apply_principal_payment(bigint, numeric, text, bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
