-- =============================================================================
-- Reverse premature loan collections (Service Counter due bug follow-up)
--
-- The first repair only fixed double-charges on still-pending rows. Instalments
-- that were collected early were left status=paid, so "Principal left" /
-- early settlement stayed far too low (e.g. ₿5M / ₿2.5M instead of ~₿20M+).
--
-- This patch:
--   • Ensures ledger allows entry_type = adjustment (refund lines)
--   • Finds paid instalments that are NOT yet due (same due rules as the fix)
--   • Refunds principal + interest to the club
--   • Re-opens those instalments as pending
--   • Restores outstanding_principal / installments_paid
--
-- Run AFTER loan_due_process_no_overcharge.sql. Safe re-run (only touches
-- paid rows that are still not due).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0) Allow adjustment (and keep every live entry_type already in use)
-- ---------------------------------------------------------------------------

DO $ledger_types$
DECLARE
  v_list text;
BEGIN
  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT entry_type AS t
    FROM public.competition_finance_ledger
    WHERE entry_type IS NOT NULL
    UNION
    SELECT unnest(ARRAY[
      'adjustment',
      'admin_one_off_injection',
      'admin_purchase_payment',
      'loan_drawdown',
      'loan_repayment_principal',
      'loan_interest_payment',
      'eos_injection',
      'medical_physio_hire',
      'medical_doctor_hire',
      'infra_maintenance'
    ])
  ) s;

  ALTER TABLE public.competition_finance_ledger
    DROP CONSTRAINT IF EXISTS competition_finance_ledger_entry_type_check;

  EXECUTE format(
    'ALTER TABLE public.competition_finance_ledger
       ADD CONSTRAINT competition_finance_ledger_entry_type_check
       CHECK (entry_type IN (%s))',
    v_list
  );
END;
$ledger_types$;

-- =============================================================================
-- Reverse premature loan collections (Service Counter due bug follow-up)
-- (functions below)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_loan_installment_is_due(
  p_loan_season_id bigint,
  p_due_season_offset integer,
  p_due_gpsl_month text,
  p_current_season_id bigint,
  p_active_gpsl_month text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_loan_ord integer;
  v_cur_ord integer;
  v_due_ord integer;
  v_active text := lower(btrim(coalesce(p_active_gpsl_month, '')));
  v_due text := lower(btrim(coalesce(p_due_gpsl_month, '')));
  v_active_sort smallint;
  v_due_sort smallint;
BEGIN
  IF p_loan_season_id IS NULL OR p_current_season_id IS NULL OR v_active = '' OR v_due = '' THEN
    RETURN false;
  END IF;

  IF v_active IN ('june', 'july') THEN
    IF v_due NOT IN ('june', 'july') THEN
      RETURN false;
    END IF;
  END IF;

  IF v_active = 'playoffs' THEN
    v_active := 'may';
  END IF;

  v_loan_ord := public.competition_season_ordinal(p_loan_season_id);
  v_cur_ord := public.competition_season_ordinal(p_current_season_id);
  IF v_loan_ord IS NULL OR v_cur_ord IS NULL THEN
    RETURN false;
  END IF;

  v_due_ord := v_loan_ord + greatest(coalesce(p_due_season_offset, 0), 0);

  IF v_cur_ord > v_due_ord THEN
    RETURN true;
  END IF;
  IF v_cur_ord < v_due_ord THEN
    RETURN false;
  END IF;

  v_active_sort := public.competition_gpsl_month_sort(v_active);
  v_due_sort := public.competition_gpsl_month_sort(v_due);
  IF v_active_sort IS NULL OR v_due_sort IS NULL THEN
    RETURN false;
  END IF;

  RETURN v_active_sort >= v_due_sort;
END;
$function$;

-- As-of GPSL month for repairs: active window, else last locked month,
-- else earliest currently-open unlocked month (never "max unlocked" which
-- can be May if the whole calendar was unlocked early).
CREATE OR REPLACE FUNCTION public.club_loan_as_of_gpsl_month(p_season_id bigint)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text;
BEGIN
  v_month := public.competition_active_gpsl_month(p_season_id, now());
  IF v_month IS NOT NULL THEN
    RETURN v_month;
  END IF;

  -- Last fully locked month = how far the season has actually progressed
  SELECT m.gpsl_month
  INTO v_month
  FROM public.competition_season_calendar m
  WHERE m.season_id = p_season_id
    AND m.lock_at IS NOT NULL
    AND m.lock_at <= now()
  ORDER BY m.sort_order DESC
  LIMIT 1;

  IF v_month IS NOT NULL THEN
    RETURN v_month;
  END IF;

  -- Earliest open unlocked window
  SELECT m.gpsl_month
  INTO v_month
  FROM public.competition_season_calendar m
  WHERE m.season_id = p_season_id
    AND m.unlock_at <= now()
    AND (m.lock_at IS NULL OR m.lock_at > now())
  ORDER BY m.sort_order ASC
  LIMIT 1;

  RETURN v_month;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_loan_reverse_premature_collections(
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_as_of text;
  v_row record;
  v_prin numeric;
  v_int numeric;
  v_total numeric;
  v_n int := 0;
  v_prin_sum numeric := 0;
  v_int_sum numeric := 0;
  v_loans int := 0;
BEGIN
  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_current_season');
  END IF;

  v_as_of := public.club_loan_as_of_gpsl_month(v_season_id);
  IF v_as_of IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_as_of_gpsl_month', 'season_id', v_season_id);
  END IF;

  FOR v_row IN
    SELECT
      i.id AS installment_id,
      i.loan_id,
      i.installment_no,
      i.due_gpsl_month,
      i.due_season_offset,
      i.paid_amount,
      i.interest_paid,
      l.club_short_name,
      l.season_id AS loan_season_id,
      l.repayment_months
    FROM public.club_loan_installments i
    JOIN public.club_loans l ON l.id = i.loan_id
    WHERE l.status IN ('active', 'paid')
      AND i.status = 'paid'
      AND (p_club_short_name IS NULL OR l.club_short_name = btrim(p_club_short_name))
      AND NOT public.club_loan_installment_is_due(
        l.season_id,
        coalesce(i.due_season_offset, 0),
        i.due_gpsl_month,
        v_season_id,
        v_as_of
      )
    ORDER BY l.club_short_name, i.loan_id, i.installment_no DESC
  LOOP
    v_prin := round(greatest(coalesce(v_row.paid_amount, 0), 0), 2);
    v_int := round(greatest(coalesce(v_row.interest_paid, 0), 0), 2);
    v_total := v_prin + v_int;
    IF v_total <= 0.005 THEN
      UPDATE public.club_loan_installments
      SET status = 'pending',
          paid_amount = 0,
          interest_paid = 0,
          paid_at = NULL
      WHERE id = v_row.installment_id;
      CONTINUE;
    END IF;

    -- Re-open instalment
    UPDATE public.club_loan_installments
    SET status = 'pending',
        paid_amount = 0,
        interest_paid = 0,
        paid_at = NULL
    WHERE id = v_row.installment_id;

    -- Restore principal on the loan
    UPDATE public.club_loans
    SET outstanding_principal = outstanding_principal + v_prin,
        status = 'active',
        closed_at = NULL,
        updated_at = now()
    WHERE id = v_row.loan_id;

    -- Refund club cash
    UPDATE public."Club_Finances"
    SET balance = balance + v_total
    WHERE club_name = v_row.club_short_name;

    PERFORM public.post_club_ledger(
      v_row.club_short_name,
      'adjustment',
      v_total,
      format(
        'Loan premature collection refund — %s inst %s/%s (loan #%s)',
        public.competition_gpsl_month_label(v_row.due_gpsl_month),
        v_row.installment_no,
        coalesce(v_row.repayment_months, 20),
        v_row.loan_id
      ),
      jsonb_build_object(
        'repair', 'club_loan_reverse_premature_collections',
        'loan_id', v_row.loan_id,
        'installment_id', v_row.installment_id,
        'installment_no', v_row.installment_no,
        'principal_refund', v_prin,
        'interest_refund', v_int,
        'as_of_gpsl_month', v_as_of
      ),
      v_season_id,
      NULL,
      false,
      false
    );

    UPDATE public.gpsl_bank_account
    SET loan_book_outstanding = loan_book_outstanding + v_prin,
        reserves = greatest(0, reserves - v_total),
        updated_at = now()
    WHERE id = 1;

    v_n := v_n + 1;
    v_prin_sum := v_prin_sum + v_prin;
    v_int_sum := v_int_sum + v_int;
  END LOOP;

  -- Refresh paid counts / outstanding sync from pending schedule
  UPDATE public.club_loans l
  SET installments_paid = (
        SELECT count(*)::int
        FROM public.club_loan_installments i
        WHERE i.loan_id = l.id AND i.status = 'paid'
      ),
      outstanding_principal = (
        SELECT coalesce(sum(greatest(0, i.principal_due - coalesce(i.paid_amount, 0))), 0)
        FROM public.club_loan_installments i
        WHERE i.loan_id = l.id AND i.status = 'pending'
      ),
      status = CASE
        WHEN (
          SELECT coalesce(sum(greatest(0, i.principal_due - coalesce(i.paid_amount, 0))), 0)
          FROM public.club_loan_installments i
          WHERE i.loan_id = l.id AND i.status = 'pending'
        ) <= 0.005 THEN 'paid'
        ELSE 'active'
      END,
      closed_at = CASE
        WHEN (
          SELECT coalesce(sum(greatest(0, i.principal_due - coalesce(i.paid_amount, 0))), 0)
          FROM public.club_loan_installments i
          WHERE i.loan_id = l.id AND i.status = 'pending'
        ) <= 0.005 THEN coalesce(l.closed_at, now())
        ELSE NULL
      END,
      updated_at = now()
  WHERE l.status IN ('active', 'paid')
    AND (p_club_short_name IS NULL OR l.club_short_name = btrim(p_club_short_name))
    AND EXISTS (
      SELECT 1 FROM public.club_loan_installments i WHERE i.loan_id = l.id
    );

  SELECT count(*)::int INTO v_loans
  FROM public.club_loans l
  WHERE l.status = 'active'
    AND (p_club_short_name IS NULL OR l.club_short_name = btrim(p_club_short_name));

  RETURN jsonb_build_object(
    'ok', true,
    'as_of_gpsl_month', v_as_of,
    'season_id', v_season_id,
    'instalments_reopened', v_n,
    'principal_refunded', v_prin_sum,
    'interest_refunded', v_int_sum,
    'active_loans', v_loans
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_loan_as_of_gpsl_month(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_reverse_premature_collections(text) TO authenticated;

-- Run for all clubs once
SELECT public.club_loan_reverse_premature_collections(NULL);

NOTIFY pgrst, 'reload schema';
