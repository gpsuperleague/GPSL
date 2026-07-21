-- =============================================================================
-- Loan schedule reconcile: June Season 2 must not collect Aug–May of Season 2
--
-- Symptom (Jun Season 2): August-drawn ₿50M loans show ~₿2.5–5M left with
-- schedule into "Season 3". Too many instalments were marked paid.
--
-- Root: due checks keyed off due_season_offset / full calendar sorts can treat
-- future buckets as already due. Visiting Service Counter then collects them.
--
-- Fix (loan calendar = Aug–May only, 10 months/season):
--   • expected_paid_count from drawdown + current season/month
--   • June/July → only completed prior loan seasons (e.g. S1 = 10 for Aug draw)
--   • Reopen+refund paid instalments beyond expected
--   • process_due only settles installment_no <= expected
--
-- Safe re-run.
-- =============================================================================

-- Loan-year month index (NOT the June–May fixture calendar)
CREATE OR REPLACE FUNCTION public.club_loan_calendar_month_sort(p_month text)
RETURNS smallint
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE lower(btrim(coalesce(p_month, '')))
    WHEN 'august' THEN 1
    WHEN 'aug' THEN 1
    WHEN 'september' THEN 2
    WHEN 'sep' THEN 2
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
    -- June/July (or unknown): only finished loan seasons before current
    -- e.g. June Season 2, loan Season 1 → 10 positions completed
    v_cur_pos := (v_cur_ord - v_loan_ord) * 10;
  ELSE
    v_cur_pos := (v_cur_ord - v_loan_ord) * 10 + v_active_loan;
  END IF;

  RETURN greatest(0, least(v_months, v_cur_pos - v_start_pos + 1));
END;
$function$;

-- is_due via expected count (needs installment_no — new overload helper used by process)
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
       p_loan_season_id,
       p_drawdown_month,
       p_repayment_months,
       p_current_season_id,
       p_active_month
     );
$$;

-- Keep old signature but route through calendar when possible via due month only as fallback
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

  -- Same loan-season bucket: compare Aug–May indexes only
  v_active_loan := public.club_loan_calendar_month_sort(v_active);
  v_due_loan := public.club_loan_calendar_month_sort(v_due);

  IF v_active_loan IS NULL THEN
    -- June/July soft months in this season → Aug–May of this bucket not due yet
    RETURN false;
  END IF;
  IF v_due_loan IS NULL THEN
    RETURN false;
  END IF;

  RETURN v_active_loan >= v_due_loan;
END;
$function$;

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
  v_expected int;
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

  v_active_month := coalesce(
    public.competition_active_gpsl_month(v_season_id, now()),
    public.club_loan_as_of_gpsl_month(v_season_id)
  );
  IF v_active_month IS NULL THEN
    RETURN jsonb_build_object('processed', 0, 'total_paid', 0, 'reason', 'no_active_gpsl_month');
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
        l.season_id,
        l.drawdown_gpsl_month,
        coalesce(l.repayment_months, 20),
        i.installment_no,
        v_season_id,
        v_active_month
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

-- Ensure as_of helper exists (from reverse patch)
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

  SELECT m.gpsl_month INTO v_month
  FROM public.competition_season_calendar m
  WHERE m.season_id = p_season_id
    AND m.lock_at IS NOT NULL
    AND m.lock_at <= now()
  ORDER BY m.sort_order DESC
  LIMIT 1;

  IF v_month IS NOT NULL THEN
    RETURN v_month;
  END IF;

  SELECT m.gpsl_month INTO v_month
  FROM public.competition_season_calendar m
  WHERE m.season_id = p_season_id
    AND m.unlock_at <= now()
    AND (m.lock_at IS NULL OR m.lock_at > now())
  ORDER BY m.sort_order ASC
  LIMIT 1;

  -- Soft default for season start
  RETURN coalesce(v_month, 'june');
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

    -- Reopen + refund anything paid beyond expected
    FOR v_inst IN
      SELECT *
      FROM public.club_loan_installments i
      WHERE i.loan_id = v_loan.id
        AND i.status = 'paid'
        AND i.installment_no > v_expected
      ORDER BY i.installment_no DESC
    LOOP
      v_prin := round(greatest(coalesce(v_inst.paid_amount, v_inst.principal_due, 0), 0), 2);
      v_int := round(greatest(coalesce(v_inst.interest_paid, 0), 0), 2);
      -- If paid_amount was zeroed somehow, still refund scheduled principal
      IF v_prin <= 0.005 THEN
        v_prin := round(greatest(coalesce(v_inst.principal_due, 0), 0), 2);
      END IF;
      v_total := v_prin + v_int;

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

        PERFORM public.post_club_ledger(
          v_loan.club_short_name,
          'adjustment',
          v_total,
          format(
            'Loan schedule restore — refund inst %s/%s (loan #%s, expected paid ≤ %s as of %s)',
            v_inst.installment_no,
            coalesce(v_loan.repayment_months, 20),
            v_loan.id,
            v_expected,
            v_as_of
          ),
          jsonb_build_object(
            'repair', 'club_loan_reconcile_expected_schedule',
            'loan_id', v_loan.id,
            'installment_id', v_inst.id,
            'installment_no', v_inst.installment_no,
            'expected_paid', v_expected,
            'as_of_gpsl_month', v_as_of,
            'principal_refund', v_prin,
            'interest_refund', v_int
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
      END IF;

      v_reopened := v_reopened + 1;
      v_refund_prin := v_refund_prin + v_prin;
      v_refund_int := v_refund_int + v_int;
    END LOOP;

    -- Mark 1..expected as paid if already settled historically but status wrong:
    -- only touch rows already with paid_amount covering principal (no new cash)
    UPDATE public.club_loan_installments i
    SET status = 'paid',
        paid_at = coalesce(i.paid_at, now()),
        paid_amount = CASE
          WHEN coalesce(i.paid_amount, 0) < i.principal_due - 0.005 THEN i.principal_due
          ELSE i.paid_amount
        END,
        interest_paid = CASE
          WHEN coalesce(i.interest_paid, 0) < coalesce(i.interest_due, 0) - 0.005
            THEN coalesce(i.interest_due, 0)
          ELSE i.interest_paid
        END
    WHERE i.loan_id = v_loan.id
      AND i.installment_no <= v_expected
      AND i.status = 'pending'
      AND coalesce(i.paid_amount, 0) >= i.principal_due - 0.005;

    -- Outstanding = unpaid principal on pending
    UPDATE public.club_loans l
    SET outstanding_principal = (
          SELECT coalesce(sum(greatest(0, i.principal_due - coalesce(i.paid_amount, 0))), 0)
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
    'note', 'June/July → expected paid = completed prior loan seasons only (10 for Aug draw into S2)'
  );
END;
$function$;

-- Widen adjustment if needed
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
    SELECT 'adjustment'
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
  RAISE NOTICE 'ledger type widen skipped: %', SQLERRM;
END;
$ledger_types$;

-- Run reconcile for all clubs
SELECT public.club_loan_reconcile_expected_schedule(NULL);

GRANT EXECUTE ON FUNCTION public.club_loan_calendar_month_sort(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_expected_paid_count(bigint, text, integer, bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_installment_is_due_by_no(bigint, text, integer, integer, bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_reconcile_expected_schedule(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_process_due_for_club(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
