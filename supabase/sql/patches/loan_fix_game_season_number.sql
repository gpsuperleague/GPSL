-- =============================================================================
-- ROOT CAUSE FIX: loan due math used competition_season_ordinal
--
-- Diagnostic (Season 2 June):
--   season_label "2" → competition_season_ordinal = 6  (test seasons in between)
--   draw season label "1" → ordinal = 1
--   expected_paid = (6-1)*10 = 50 → capped at 20
--   → reconcile thinks nothing is overpaid
--   → is_due: cur_ord 6 > due_ord 2 → ALL Season-2 instalments look due
--
-- Fix: use game season NUMBER from competition_seasons.label (1, 2, …)
-- for loan schedule math only. Do NOT change competition_season_ordinal
-- (other systems may rely on row order).
--
-- Then reconcile: reopen instalments beyond expected; refund; clear phantom
-- Season 2 loan ledger rows.
--
-- Safe re-run. Keep client auto-collect OFF until verified.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_loan_game_season_number(p_season_id bigint)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN nullif(btrim(s.label), '') ~ '^[0-9]+$' THEN btrim(s.label)::integer
    WHEN nullif(btrim(s.label), '') ~ '[0-9]+' THEN
      (regexp_match(btrim(s.label), '[0-9]+'))[1]::integer
    ELSE public.competition_season_ordinal(p_season_id)
  END
  FROM public.competition_seasons s
  WHERE s.id = p_season_id;
$$;

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

  -- Game labels (1, 2), NOT DB row_number ordinals
  v_loan_ord := public.club_loan_game_season_number(p_loan_season_id);
  v_cur_ord := public.club_loan_game_season_number(p_current_season_id);
  IF v_loan_ord IS NULL OR v_cur_ord IS NULL OR v_cur_ord < v_loan_ord THEN
    RETURN 0;
  END IF;

  v_draw := coalesce(public.club_loan_calendar_month_sort(p_drawdown_month), 1);
  v_first_ahead := public.club_loan_first_months_ahead(p_drawdown_month);
  v_start_pos := v_draw + v_first_ahead;

  v_active_loan := public.club_loan_calendar_month_sort(v_active);
  IF v_active_loan IS NULL THEN
    -- June/July: only completed prior game seasons
    v_cur_pos := (v_cur_ord - v_loan_ord) * 10;
  ELSE
    v_cur_pos := (v_cur_ord - v_loan_ord) * 10 + v_active_loan;
  END IF;

  RETURN greatest(0, least(v_months, v_cur_pos - v_start_pos + 1));
END;
$function$;

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
  v_active_loan smallint;
  v_due_loan smallint;
BEGIN
  IF p_loan_season_id IS NULL OR p_current_season_id IS NULL OR v_active = '' OR v_due = '' THEN
    RETURN false;
  END IF;

  IF v_active = 'playoffs' THEN
    v_active := 'may';
  END IF;

  v_loan_ord := public.club_loan_game_season_number(p_loan_season_id);
  v_cur_ord := public.club_loan_game_season_number(p_current_season_id);
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

  v_active_loan := public.club_loan_calendar_month_sort(v_active);
  v_due_loan := public.club_loan_calendar_month_sort(v_due);

  IF v_active_loan IS NULL THEN
    -- June/July in this game season → Aug–May of this bucket not due yet
    RETURN false;
  END IF;
  IF v_due_loan IS NULL THEN
    RETURN false;
  END IF;

  RETURN v_active_loan >= v_due_loan;
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
    'active_gpsl_month', v_active_month,
    'game_season_number', public.club_loan_game_season_number(v_season_id)
  );
END;
$function$;

-- Pre-check: must show expected 10 for Aug S1 draws in June S2 (not 20)
SELECT
  l.id AS loan_id,
  l.club_short_name,
  l.drawdown_gpsl_month,
  public.club_loan_game_season_number(l.season_id) AS draw_game_season,
  public.club_loan_game_season_number(s.id) AS current_game_season,
  public.competition_season_ordinal(s.id) AS current_db_ordinal_WRONG_for_loans,
  public.club_loan_expected_paid_count(
    l.season_id, l.drawdown_gpsl_month, 20, s.id, 'june'
  ) AS expected_paid_june,
  (SELECT count(*) FROM public.club_loan_installments i
    WHERE i.loan_id = l.id AND i.status = 'paid') AS actual_paid
FROM public.club_loans l
CROSS JOIN public.competition_seasons s
WHERE s.is_current = true
  AND l.status IN ('active', 'paid')
  AND l.club_short_name = 'JUB'
ORDER BY l.id;

-- Reconcile (reopen + refund + delete phantom S2 loan ledger lines)
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

  v_as_of := coalesce(
    public.competition_active_gpsl_month(v_season_id, now()),
    public.club_loan_as_of_gpsl_month(v_season_id),
    'june'
  );

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
    'game_season_number', public.club_loan_game_season_number(v_season_id),
    'db_ordinal_not_used', public.competition_season_ordinal(v_season_id),
    'loans', v_loans,
    'instalments_reopened', v_reopened,
    'principal_refunded', v_refund_prin,
    'interest_refunded', v_refund_int,
    'ledger_rows_deleted', v_ledger_deleted
  );
END;
$function$;

-- JUB only first (your club) — safer than all clubs in one go
SELECT public.club_loan_reconcile_expected_schedule('JUB') AS jub_reconcile;

GRANT EXECUTE ON FUNCTION public.club_loan_game_season_number(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_expected_paid_count(bigint, text, integer, bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_installment_is_due(bigint, integer, text, bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_installment_is_due_by_no(bigint, text, integer, integer, bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_process_due_for_club(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_reconcile_expected_schedule(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
