-- =============================================================================
-- FORCE June Season 2 loan reconcile (Aug/Sep S1 draws)
--
-- UI: Season 2 · June → ZERO Season 2 loan collections should have happened.
-- Service counter wrongly shows ~₿2.5M / ₿5M early settle (almost fully paid).
-- Season accounts show Season 2 loan principal −₿12.5M even though June = ₿0.
--
-- Likely cause: as-of month resolved to May (last locked), so "expected paid"
-- became 20 and the prior reconcile reopened nothing.
--
-- This patch:
--   1) as_of = June/July while August of the current season is not unlocked
--   2) expected paid from Aug–May loan calendar only
--   3) Reopen instalments beyond expected; refund cash; DELETE phantom S2
--      loan_repayment_principal / loan_interest_payment ledger rows
--   4) process_due uses installment_no ≤ expected only
--
-- Run in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_loan_calendar_month_sort(p_month text)
RETURNS smallint
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(coalesce(p_month, '')))
    WHEN 'august' THEN 1 WHEN 'aug' THEN 1
    WHEN 'september' THEN 2 WHEN 'sep' THEN 2
    WHEN 'october' THEN 3
    WHEN 'november' THEN 4
    WHEN 'december' THEN 5
    WHEN 'january' THEN 6
    WHEN 'february' THEN 7
    WHEN 'march' THEN 8
    WHEN 'april' THEN 9
    WHEN 'may' THEN 10
    ELSE NULL
  END;
$$;

-- Before August unlock of current season → soft June/July (loan year not started)
CREATE OR REPLACE FUNCTION public.club_loan_as_of_gpsl_month(p_season_id bigint)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_month text;
  v_aug_unlock timestamptz;
  v_june_unlock timestamptz;
  v_july_unlock timestamptz;
BEGIN
  v_month := public.competition_active_gpsl_month(p_season_id, now());
  IF v_month IS NOT NULL THEN
    RETURN lower(v_month);
  END IF;

  SELECT m.unlock_at INTO v_aug_unlock
  FROM public.competition_season_calendar m
  WHERE m.season_id = p_season_id AND m.gpsl_month = 'august'
  LIMIT 1;

  SELECT m.unlock_at INTO v_june_unlock
  FROM public.competition_season_calendar m
  WHERE m.season_id = p_season_id AND m.gpsl_month = 'june'
  LIMIT 1;

  SELECT m.unlock_at INTO v_july_unlock
  FROM public.competition_season_calendar m
  WHERE m.season_id = p_season_id AND m.gpsl_month = 'july'
  LIMIT 1;

  -- Soft start: August not unlocked yet → still June/July for loans
  IF v_aug_unlock IS NOT NULL AND now() < v_aug_unlock THEN
    IF v_july_unlock IS NOT NULL AND now() >= v_july_unlock THEN
      RETURN 'july';
    END IF;
    RETURN 'june';
  END IF;

  -- Last locked loan-calendar month (Aug–May only)
  SELECT m.gpsl_month INTO v_month
  FROM public.competition_season_calendar m
  WHERE m.season_id = p_season_id
    AND m.gpsl_month IN (
      'august','september','october','november','december',
      'january','february','march','april','may'
    )
    AND m.lock_at IS NOT NULL
    AND m.lock_at <= now()
  ORDER BY public.club_loan_calendar_month_sort(m.gpsl_month) DESC NULLS LAST
  LIMIT 1;

  IF v_month IS NOT NULL THEN
    RETURN lower(v_month);
  END IF;

  RETURN 'june';
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_loan_expected_paid_count(
  p_loan_season_id bigint,
  p_drawdown_month text,
  p_repayment_months integer,
  p_current_season_id bigint,
  p_active_month text
)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_loan_ord integer;
  v_cur_ord integer;
  v_draw integer;
  v_first_ahead integer;
  v_start_pos integer;
  v_cur_pos integer;
  v_active text := lower(btrim(coalesce(p_active_month, '')));
  v_active_loan integer;
  v_months integer := greatest(coalesce(p_repayment_months, 20), 0);
BEGIN
  IF p_loan_season_id IS NULL OR p_current_season_id IS NULL OR v_months <= 0 THEN
    RETURN 0;
  END IF;

  IF v_active = 'playoffs' THEN
    v_active := 'may';
  END IF;

  v_loan_ord := public.competition_season_ordinal(p_loan_season_id);
  v_cur_ord := public.competition_season_ordinal(p_current_season_id);
  IF v_loan_ord IS NULL OR v_cur_ord IS NULL OR v_cur_ord < v_loan_ord THEN
    RETURN 0;
  END IF;

  v_draw := coalesce(public.club_loan_calendar_month_sort(p_drawdown_month), 1);
  v_first_ahead := public.club_loan_first_months_ahead(p_drawdown_month);
  v_start_pos := v_draw + v_first_ahead;

  v_active_loan := public.club_loan_calendar_month_sort(v_active);
  IF v_active_loan IS NULL THEN
    -- June/July: only prior completed loan seasons (S2 June, S1 Aug loan → 10)
    v_cur_pos := (v_cur_ord - v_loan_ord) * 10;
  ELSE
    v_cur_pos := (v_cur_ord - v_loan_ord) * 10 + v_active_loan;
  END IF;

  RETURN greatest(0, least(v_months, v_cur_pos - v_start_pos + 1));
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_loan_installment_is_due_by_no(
  p_loan_season_id bigint,
  p_drawdown_month text,
  p_repayment_months integer,
  p_installment_no integer,
  p_current_season_id bigint,
  p_active_month text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(p_installment_no, 0) > 0
     AND coalesce(p_installment_no, 0) <= public.club_loan_expected_paid_count(
       p_loan_season_id, p_drawdown_month, p_repayment_months,
       p_current_season_id, p_active_month
     );
$$;

CREATE OR REPLACE FUNCTION public.club_loan_process_due_for_club(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_active_month text;
  v_inst record;
  v_paid numeric := 0;
  v_count int := 0;
  v_skipped int := 0;
  v_errors int := 0;
BEGIN
  IF p_club IS NULL OR btrim(p_club) = '' THEN
    RETURN jsonb_build_object('processed', 0, 'total_paid', 0);
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('processed', 0, 'total_paid', 0, 'reason', 'no_active_season');
  END IF;

  v_active_month := public.club_loan_as_of_gpsl_month(v_season_id);
  IF v_active_month IS NULL THEN
    RETURN jsonb_build_object('processed', 0, 'total_paid', 0, 'reason', 'no_as_of_month');
  END IF;

  -- Soft months: do not auto-collect anything for the current season's loan year
  IF lower(v_active_month) IN ('june', 'july') THEN
    -- Still allow catching up unpaid PRIOR season instalments only
    NULL;
  END IF;

  FOR v_inst IN
    SELECT i.*, l.season_id AS loan_season_id, l.drawdown_gpsl_month, l.repayment_months
    FROM public.club_loan_installments i
    JOIN public.club_loans l ON l.id = i.loan_id
    WHERE l.club_short_name = btrim(p_club)
      AND l.status = 'active'
      AND i.status = 'pending'
      AND l.drawdown_gpsl_month IS NOT NULL
      AND public.club_loan_installment_is_due_by_no(
        l.season_id, l.drawdown_gpsl_month, coalesce(l.repayment_months, 20),
        i.installment_no, v_season_id, v_active_month
      )
    ORDER BY i.installment_no
  LOOP
    BEGIN
      v_paid := v_paid + public.club_loan_settle_scheduled_installment(v_inst.id);
      v_count := v_count + 1;
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM ILIKE '%Insufficient balance%' THEN
          v_skipped := v_skipped + 1;
          EXIT;
        END IF;
        v_errors := v_errors + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'processed', v_count,
    'total_paid', v_paid,
    'skipped_insufficient', v_skipped,
    'errors', v_errors,
    'active_gpsl_month', v_active_month
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_loan_reconcile_expected_schedule(
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
  v_loan record;
  v_inst record;
  v_expected int;
  v_prin numeric;
  v_int numeric;
  v_total numeric;
  v_reopened int := 0;
  v_refund_prin numeric := 0;
  v_refund_int numeric := 0;
  v_ledger_deleted int := 0;
  v_loans int := 0;
  v_del int;
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

  FOR v_loan IN
    SELECT *
    FROM public.club_loans l
    WHERE l.status IN ('active', 'paid')
      AND (p_club_short_name IS NULL OR l.club_short_name = btrim(p_club_short_name))
    ORDER BY l.id
  LOOP
    v_loans := v_loans + 1;
    v_expected := public.club_loan_expected_paid_count(
      v_loan.season_id,
      v_loan.drawdown_gpsl_month,
      coalesce(v_loan.repayment_months, 20),
      v_season_id,
      v_as_of
    );

    FOR v_inst IN
      SELECT *
      FROM public.club_loan_installments i
      WHERE i.loan_id = v_loan.id
        AND i.status IN ('paid', 'skipped')
        AND i.installment_no > v_expected
      ORDER BY i.installment_no DESC
    LOOP
      -- Prefer amounts actually taken from the ledger (settle may leave interest_paid=0)
      SELECT coalesce(sum(abs(l.amount)), 0) INTO v_prin
      FROM public.competition_finance_ledger l
      WHERE l.entry_type = 'loan_repayment_principal'
        AND coalesce(l.metadata->>'installment_id', '') = v_inst.id::text;
      IF v_prin <= 0.005 THEN
        v_prin := round(greatest(
          coalesce(nullif(v_inst.paid_amount, 0), v_inst.principal_due, 0), 0), 2);
      END IF;

      SELECT coalesce(sum(abs(l.amount)), 0) INTO v_int
      FROM public.competition_finance_ledger l
      WHERE l.entry_type = 'loan_interest_payment'
        AND coalesce(l.metadata->>'installment_id', '') = v_inst.id::text;
      IF v_int <= 0.005 THEN
        v_int := round(greatest(coalesce(v_inst.interest_paid, 0), 0), 2);
      END IF;

      v_total := round(v_prin + v_int, 2);

      -- Remove phantom ledger lines for this instalment (clears Season 2 accounts)
      DELETE FROM public.competition_finance_ledger l
      WHERE l.entry_type IN ('loan_repayment_principal', 'loan_interest_payment')
        AND coalesce(l.metadata->>'installment_id', '') = v_inst.id::text;
      GET DIAGNOSTICS v_del = ROW_COUNT;
      v_ledger_deleted := v_ledger_deleted + v_del;

      UPDATE public.club_loan_installments
      SET status = 'pending',
          paid_amount = 0,
          interest_paid = 0,
          paid_at = NULL
      WHERE id = v_inst.id;

      IF v_total > 0.005 THEN
        UPDATE public."Club_Finances"
        SET balance = balance + v_total
        WHERE club_name = v_loan.club_short_name;

        UPDATE public.gpsl_bank_account
        SET loan_book_outstanding = loan_book_outstanding + v_prin,
            reserves = greatest(0, reserves - v_total),
            updated_at = now()
        WHERE id = 1;
      END IF;

      v_reopened := v_reopened + 1;
      v_refund_prin := v_refund_prin + v_prin;
      v_refund_int := v_refund_int + v_int;
    END LOOP;

    -- Ensure 1..expected stay paid when already collected in S1
    UPDATE public.club_loan_installments i
    SET status = 'paid',
        paid_at = coalesce(i.paid_at, now()),
        paid_amount = greatest(coalesce(i.paid_amount, 0), i.principal_due),
        interest_paid = greatest(coalesce(i.interest_paid, 0), coalesce(i.interest_due, 0))
    WHERE i.loan_id = v_loan.id
      AND i.installment_no <= v_expected
      AND i.status = 'pending'
      AND coalesce(i.paid_amount, 0) >= i.principal_due - 0.005;

    UPDATE public.club_loans l
    SET outstanding_principal = (
          SELECT coalesce(sum(i.principal_due), 0)
          FROM public.club_loan_installments i
          WHERE i.loan_id = l.id AND i.status = 'pending'
        ),
        installments_paid = (
          SELECT count(*)::int
          FROM public.club_loan_installments i
          WHERE i.loan_id = l.id AND i.status = 'paid'
        ),
        status = 'active',
        closed_at = NULL,
        updated_at = now()
    WHERE l.id = v_loan.id;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'as_of_gpsl_month', v_as_of,
    'season_id', v_season_id,
    'loans', v_loans,
    'instalments_reopened', v_reopened,
    'principal_refunded', v_refund_prin,
    'interest_refunded', v_refund_int,
    'ledger_rows_deleted', v_ledger_deleted,
    'expect', jsonb_build_object(
      'august_s1_loan_in_june_s2', 10,
      'september_s1_loan_in_june_s2', 8,
      'outstanding_aug_50m', 25000000,
      'outstanding_sep_50m', 30000000
    )
  );
END;
$function$;

-- Allow deletes on ledger for this repair (no type issues)
DO $ledger_types$
DECLARE
  v_list text;
BEGIN
  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT entry_type AS t FROM public.competition_finance_ledger WHERE entry_type IS NOT NULL
    UNION SELECT 'adjustment'
  ) s;
  ALTER TABLE public.competition_finance_ledger
    DROP CONSTRAINT IF EXISTS competition_finance_ledger_entry_type_check;
  EXECUTE format(
    'ALTER TABLE public.competition_finance_ledger
       ADD CONSTRAINT competition_finance_ledger_entry_type_check
       CHECK (entry_type IN (%s))',
    v_list
  );
EXCEPTION WHEN OTHERS THEN
  NULL;
END;
$ledger_types$;

SELECT public.club_loan_reconcile_expected_schedule(NULL) AS reconcile_result;

GRANT EXECUTE ON FUNCTION public.club_loan_as_of_gpsl_month(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_expected_paid_count(bigint, text, integer, bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_installment_is_due_by_no(bigint, text, integer, integer, bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_reconcile_expected_schedule(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_process_due_for_club(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
