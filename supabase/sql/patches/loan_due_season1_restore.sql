-- =============================================================================
-- Fix loan due-check: Season 1 payments must stay counted
--
-- Bug: club_loan_installment_is_due() treated June/July as "nothing Aug–May is
-- due" for ALL seasons. During Season 2 June/July soft months that made every
-- Season 1 Aug–May instalment look "not due", so
-- club_loan_reverse_premature_collections() refunded and re-opened them —
-- settlement reset to full principal.
--
-- Fix:
--   1) June/July soft-month gate only applies to the instalment's own season
--      bucket (same due_ord as current). Past season buckets stay due.
--   2) Reverse-premature only reopens CURRENT/FUTURE buckets (never past).
--   3) Re-collect truly due pending instalments so Season 1 is factored back in.
--
-- Safe re-run.
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

  IF v_active = 'playoffs' THEN
    v_active := 'may';
  END IF;

  v_loan_ord := public.competition_season_ordinal(p_loan_season_id);
  v_cur_ord := public.competition_season_ordinal(p_current_season_id);
  IF v_loan_ord IS NULL OR v_cur_ord IS NULL THEN
    RETURN false;
  END IF;

  v_due_ord := v_loan_ord + greatest(coalesce(p_due_season_offset, 0), 0);

  -- Past season bucket (e.g. Season 1 schedule while living in Season 2) → due
  IF v_cur_ord > v_due_ord THEN
    RETURN true;
  END IF;

  -- Future season bucket → not due
  IF v_cur_ord < v_due_ord THEN
    RETURN false;
  END IF;

  -- Same season as this instalment's due bucket:
  -- June/July soft months do not unlock Aug–May dues yet
  IF v_active IN ('june', 'july') AND v_due NOT IN ('june', 'july') THEN
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

-- Tighten reverse: never reopen past-season (already-due) instalments
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
  v_loan_ord integer;
  v_cur_ord integer;
  v_due_ord integer;
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

  v_cur_ord := public.competition_season_ordinal(v_season_id);

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
    -- Extra guard: never reverse a past season-bucket instalment
    v_loan_ord := public.competition_season_ordinal(v_row.loan_season_id);
    v_due_ord := coalesce(v_loan_ord, 0) + greatest(coalesce(v_row.due_season_offset, 0), 0);
    IF v_cur_ord IS NOT NULL AND v_due_ord < v_cur_ord THEN
      CONTINUE;
    END IF;

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

    UPDATE public.club_loan_installments
    SET status = 'pending',
        paid_amount = 0,
        interest_paid = 0,
        paid_at = NULL
    WHERE id = v_row.installment_id;

    UPDATE public.club_loans
    SET outstanding_principal = outstanding_principal + v_prin,
        status = 'active',
        closed_at = NULL,
        updated_at = now()
    WHERE id = v_row.loan_id;

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

-- Re-apply Season 1 (and any other truly due) pending instalments after the bad reverse
DO $recollect$
DECLARE
  r record;
  v_res jsonb;
  v_clubs int := 0;
  v_paid numeric := 0;
  v_proc int := 0;
BEGIN
  FOR r IN
    SELECT DISTINCT l.club_short_name
    FROM public.club_loans l
    WHERE l.status = 'active'
    ORDER BY 1
  LOOP
    v_res := public.club_loan_process_due_for_club(r.club_short_name);
    v_clubs := v_clubs + 1;
    v_proc := v_proc + coalesce((v_res->>'processed')::int, 0);
    v_paid := v_paid + coalesce((v_res->>'total_paid')::numeric, 0);
  END LOOP;

  RAISE NOTICE
    'loan_due_season1_restore: clubs=% processed_instalments=% total_paid=%',
    v_clubs, v_proc, v_paid;
END;
$recollect$;

GRANT EXECUTE ON FUNCTION public.club_loan_installment_is_due(bigint, integer, text, bigint, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_reverse_premature_collections(text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
