-- =============================================================================
-- Repair wrongful early loan instalments (e.g. inst 10/20 pinned to Season 1).
-- Refunds out-of-sequence payments, restores loan principal, rebuilds schedule.
-- Run after 2025-06-08_loan_installment_due_fix.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_loan_repair_out_of_sequence_payments(p_loan_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  r record;
  v_principal_refund numeric := 0;
  v_interest_refund numeric := 0;
  v_total_refund numeric := 0;
  v_loans_fixed int := 0;
  v_season_id bigint;
BEGIN
  IF NOT (
    public.is_gpsl_admin()
    OR current_user IN ('postgres', 'supabase_admin', 'service_role')
  ) THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No active competition season';
  END IF;

  FOR r IN
    SELECT
      l.id,
      l.club_short_name,
      l.season_id AS loan_season_id,
      l.principal_drawn,
      l.drawdown_gpsl_month,
      l.repayment_months,
      l.interest_rate_pct,
      coalesce((
        SELECT sum(i.paid_amount)
        FROM public.club_loan_installments i
        WHERE i.loan_id = l.id
          AND i.status = 'paid'
          AND EXISTS (
            SELECT 1
            FROM public.club_loan_installments p
            WHERE p.loan_id = l.id
              AND p.status = 'pending'
              AND p.installment_no < i.installment_no
          )
      ), 0) AS principal_refund,
      coalesce((
        SELECT sum(i.interest_paid)
        FROM public.club_loan_installments i
        WHERE i.loan_id = l.id
          AND i.status = 'paid'
          AND EXISTS (
            SELECT 1
            FROM public.club_loan_installments p
            WHERE p.loan_id = l.id
              AND p.status = 'pending'
              AND p.installment_no < i.installment_no
          )
      ), 0) AS interest_refund
    FROM public.club_loans l
    WHERE l.status IN ('active', 'paid')
      AND (p_loan_id IS NULL OR l.id = p_loan_id)
      AND EXISTS (
        SELECT 1
        FROM public.club_loan_installments i
        WHERE i.loan_id = l.id
          AND i.status = 'paid'
          AND EXISTS (
            SELECT 1
            FROM public.club_loan_installments p
            WHERE p.loan_id = l.id
              AND p.status = 'pending'
              AND p.installment_no < i.installment_no
          )
      )
  LOOP
    v_principal_refund := round(r.principal_refund, 2);
    v_interest_refund := round(r.interest_refund, 2);
    v_total_refund := v_principal_refund + v_interest_refund;

    IF v_total_refund <= 0 THEN
      CONTINUE;
    END IF;

    PERFORM public.post_club_ledger(
      r.club_short_name,
      'adjustment',
      v_total_refund,
      format(
        'Reversal — incorrect early loan instalments (loan #%s, refunded %s principal + %s interest)',
        r.id,
        v_principal_refund,
        v_interest_refund
      ),
      jsonb_build_object(
        'loan_id', r.id,
        'repair', 'club_loan_repair_out_of_sequence_payments',
        'principal_refund', v_principal_refund,
        'interest_refund', v_interest_refund
      ),
      coalesce(r.loan_season_id, v_season_id),
      NULL,
      false,
      true
    );

    UPDATE public.gpsl_bank_account
    SET loan_book_outstanding = loan_book_outstanding + v_principal_refund,
        reserves = greatest(0, reserves - v_total_refund),
        updated_at = now()
    WHERE id = 1;

    UPDATE public.club_loans
    SET outstanding_principal = greatest(
          0,
          round(outstanding_principal + v_principal_refund, 2)
        ),
        status = 'active',
        closed_at = NULL,
        installments_paid = 0,
        updated_at = now()
    WHERE id = r.id;

    PERFORM public.club_loan_generate_installments(
      r.id,
      r.principal_drawn,
      r.loan_season_id,
      r.drawdown_gpsl_month,
      coalesce(r.repayment_months, 20)::smallint,
      r.interest_rate_pct
    );

    v_loans_fixed := v_loans_fixed + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'loans_fixed', v_loans_fixed,
    'note', 'Out-of-sequence instalments refunded; schedules rebuilt from instalment 1'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_loan_repair_out_of_sequence_payments(bigint) TO authenticated;

-- Run repair for all affected loans (typically URD loan #1).
SELECT public.club_loan_repair_out_of_sequence_payments(NULL);

NOTIFY pgrst, 'reload schema';
