-- =============================================================================
-- Fix: Service counter draining loans on every visit
--
-- Cause:
--   club_loan_process_my_due_installments() runs on each Service Counter (and
--   Finances) visit. Due matching used club_loan_gpsl_months_elapsed() with
--   (season_delta * 10 + month_sort_delta). After June/July calendar weeks,
--   competition_gpsl_month_sort goes 1..12 (june..may), so elapsed balloons and
--   many future instalments look "due". Each visit then settles the next ones
--   the club can afford → outstanding drops every refresh.
--
-- Fix:
--   1) Due = due_season_offset + due GPSL month vs current season/month
--      (playoffs counts as May for loan dues; June/July do not unlock Aug+)
--   2) Settle only remaining principal/interest on an instalment (no double hit)
--   3) Mark fully-paid instalments; repair over-collected principal where possible
--
-- Run in Supabase SQL Editor. Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Is this instalment due yet?
-- ---------------------------------------------------------------------------

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

  -- Soft months before the loan calendar (Aug–May): nothing Aug+ is due yet
  IF v_active IN ('june', 'july') THEN
    IF v_due NOT IN ('june', 'july') THEN
      RETURN false;
    END IF;
  END IF;

  -- Playoffs = end of season → treat as May for dues
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

-- ---------------------------------------------------------------------------
-- 2) Principal apply — only charge remaining on the instalment
-- ---------------------------------------------------------------------------

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
  v_ledger_season bigint;
  v_due_season bigint;
  v_remaining numeric;
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

  v_due_season := NULL;
  IF p_installment_id IS NOT NULL THEN
    SELECT
      greatest(0, principal_due - coalesce(paid_amount, 0)),
      due_season_id
    INTO v_remaining, v_due_season
    FROM public.club_loan_installments
    WHERE id = p_installment_id
      AND loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Installment not found';
    END IF;

    -- Already principal-complete for this instalment — do not charge again
    IF v_remaining <= 0.005 THEN
      RETURN 0;
    END IF;
    v_pay := least(v_pay, v_remaining);
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
          WHEN paid_amount + v_pay >= principal_due - 0.005
            AND interest_paid >= coalesce(interest_due, 0) - 0.005 THEN now()
          ELSE paid_at
        END,
        status = CASE
          WHEN paid_amount + v_pay >= principal_due - 0.005
            AND interest_paid >= coalesce(interest_due, 0) - 0.005 THEN 'paid'
          ELSE status
        END
    WHERE id = p_installment_id
      AND loan_id = p_loan_id;
  END IF;

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

-- ---------------------------------------------------------------------------
-- 3) Settle one instalment (remaining amounts only)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_loan_settle_scheduled_installment(p_installment_id bigint)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_inst record;
  v_total numeric;
  v_balance numeric;
  v_paid numeric := 0;
  v_prin_left numeric;
  v_int_left numeric;
  v_desc text;
  v_months smallint;
  v_season_label text;
BEGIN
  SELECT
    i.*,
    l.club_short_name,
    l.repayment_months,
    l.season_id AS loan_season_id,
    l.id AS loan_id
  INTO v_inst
  FROM public.club_loan_installments i
  JOIN public.club_loans l ON l.id = i.loan_id
  WHERE i.id = p_installment_id
    AND i.status = 'pending'
    AND l.status = 'active'
  FOR UPDATE OF i, l;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  v_prin_left := greatest(0, round(v_inst.principal_due - coalesce(v_inst.paid_amount, 0), 2));
  v_int_left := greatest(0, round(coalesce(v_inst.interest_due, 0) - coalesce(v_inst.interest_paid, 0), 2));
  v_total := v_prin_left + v_int_left;

  IF v_total <= 0.005 THEN
    UPDATE public.club_loan_installments
    SET status = 'paid',
        paid_at = coalesce(paid_at, now())
    WHERE id = p_installment_id;
    RETURN 0;
  END IF;

  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_inst.club_short_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Club_Finances row missing';
  END IF;

  IF v_balance < v_total THEN
    RAISE EXCEPTION 'Insufficient balance for installment % (need %, balance %)',
      p_installment_id, v_total, v_balance;
  END IF;

  v_months := coalesce(v_inst.repayment_months, 20);
  v_season_label := public.club_loan_due_season_label(
    v_inst.loan_season_id,
    coalesce(v_inst.due_season_offset, 0)
  );

  IF v_prin_left > 0.005 THEN
    v_desc := format(
      'Scheduled loan repayment — %s %s (inst %s/%s, loan #%s)',
      public.competition_gpsl_month_label(v_inst.due_gpsl_month),
      v_season_label,
      v_inst.installment_no,
      v_months,
      v_inst.loan_id
    );
    v_paid := v_paid + public.club_loan_apply_principal_payment(
      v_inst.loan_id,
      v_prin_left,
      v_desc,
      p_installment_id
    );
  END IF;

  IF v_int_left > 0.005 THEN
    v_paid := v_paid + public.club_loan_apply_interest_payment(
      v_inst.loan_id,
      v_int_left,
      format(
        'Loan interest — %s %s (inst %s/%s, loan #%s)',
        public.competition_gpsl_month_label(v_inst.due_gpsl_month),
        v_season_label,
        v_inst.installment_no,
        v_months,
        v_inst.loan_id
      ),
      p_installment_id
    );
  END IF;

  UPDATE public.club_loan_installments
  SET status = CASE
        WHEN paid_amount >= principal_due - 0.005
         AND interest_paid >= coalesce(interest_due, 0) - 0.005 THEN 'paid'
        ELSE status
      END,
      paid_at = CASE
        WHEN paid_amount >= principal_due - 0.005
         AND interest_paid >= coalesce(interest_due, 0) - 0.005
          THEN coalesce(paid_at, now())
        ELSE paid_at
      END
  WHERE id = p_installment_id;

  UPDATE public.club_loans
  SET installments_paid = (
        SELECT count(*)::int
        FROM public.club_loan_installments i
        WHERE i.loan_id = v_inst.loan_id
          AND i.status = 'paid'
      ),
      updated_at = now()
  WHERE id = v_inst.loan_id;

  RETURN v_paid;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4) Process due — calendar due check (not broken *10 elapsed)
-- ---------------------------------------------------------------------------

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

  -- Close out instalments that are already fully paid but still pending
  UPDATE public.club_loan_installments i
  SET status = 'paid',
      paid_at = coalesce(i.paid_at, now())
  FROM public.club_loans l
  WHERE l.id = i.loan_id
    AND l.club_short_name = btrim(p_club)
    AND l.status = 'active'
    AND i.status = 'pending'
    AND i.paid_amount >= i.principal_due - 0.005
    AND i.interest_paid >= coalesce(i.interest_due, 0) - 0.005;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('processed', 0, 'total_paid', 0, 'reason', 'no_active_season');
  END IF;

  v_active_month := public.competition_active_gpsl_month(v_season_id, now());
  IF v_active_month IS NULL THEN
    RETURN jsonb_build_object(
      'processed', 0,
      'total_paid', 0,
      'reason', 'no_active_gpsl_month'
    );
  END IF;

  FOR v_inst IN
    SELECT i.*, l.season_id AS loan_season_id, l.drawdown_gpsl_month
    FROM public.club_loan_installments i
    JOIN public.club_loans l ON l.id = i.loan_id
    WHERE l.club_short_name = btrim(p_club)
      AND l.status = 'active'
      AND i.status = 'pending'
      AND public.club_loan_installment_is_due(
        l.season_id,
        coalesce(i.due_season_offset, 0),
        i.due_gpsl_month,
        v_season_id,
        v_active_month
      )
    ORDER BY coalesce(i.due_season_offset, 0),
             public.competition_gpsl_month_sort(i.due_gpsl_month),
             i.installment_no
  LOOP
    BEGIN
      v_paid := v_paid + public.club_loan_settle_scheduled_installment(v_inst.id);
      v_count := v_count + 1;
    EXCEPTION
      WHEN OTHERS THEN
        -- Insufficient balance / lock — stop further dues this pass
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

CREATE OR REPLACE FUNCTION public.club_loan_process_my_due_installments()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;
  RETURN public.club_loan_process_due_for_club(v_club);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5) Repair: mark complete pending rows; restore outstanding from schedule
-- ---------------------------------------------------------------------------

DO $repair$
DECLARE
  r record;
  v_should numeric;
  v_refund numeric;
  v_season bigint;
BEGIN
  SELECT id INTO v_season
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  -- Cap over-paid principal on still-pending instalments and refund clubs
  FOR r IN
    SELECT
      i.id AS installment_id,
      i.loan_id,
      l.club_short_name,
      round(i.paid_amount - i.principal_due, 2) AS excess
    FROM public.club_loan_installments i
    JOIN public.club_loans l ON l.id = i.loan_id
    WHERE l.status = 'active'
      AND i.status = 'pending'
      AND i.paid_amount > i.principal_due + 0.005
  LOOP
    v_refund := r.excess;
    UPDATE public.club_loan_installments
    SET paid_amount = principal_due
    WHERE id = r.installment_id;

    UPDATE public.club_loans
    SET outstanding_principal = outstanding_principal + v_refund,
        updated_at = now()
    WHERE id = r.loan_id;

    UPDATE public."Club_Finances"
    SET balance = balance + v_refund
    WHERE club_name = r.club_short_name;

    PERFORM public.post_club_ledger(
      r.club_short_name,
      'adjustment',
      v_refund,
      format(
        'Loan over-collection refund — instalment #%s / loan #%s (service-counter due bug)',
        r.installment_id,
        r.loan_id
      ),
      jsonb_build_object(
        'repair', 'loan_due_process_no_overcharge',
        'loan_id', r.loan_id,
        'installment_id', r.installment_id,
        'excess_principal', v_refund
      ),
      v_season,
      NULL,
      false,
      false
    );

    UPDATE public.gpsl_bank_account
    SET loan_book_outstanding = loan_book_outstanding + v_refund,
        reserves = greatest(0, reserves - v_refund),
        updated_at = now()
    WHERE id = 1;
  END LOOP;

  -- Mark instalments that are fully satisfied
  UPDATE public.club_loan_installments
  SET status = 'paid',
      paid_at = coalesce(paid_at, now())
  WHERE status = 'pending'
    AND paid_amount >= principal_due - 0.005
    AND interest_paid >= coalesce(interest_due, 0) - 0.005;

  -- Re-sync outstanding to unpaid principal on pending schedule;
  -- if outstanding was driven too low by over-collection, credit the club back.
  FOR r IN
    SELECT l.id AS loan_id, l.club_short_name, l.outstanding_principal
    FROM public.club_loans l
    WHERE l.status = 'active'
  LOOP
    SELECT coalesce(sum(greatest(0, i.principal_due - coalesce(i.paid_amount, 0))), 0)
    INTO v_should
    FROM public.club_loan_installments i
    WHERE i.loan_id = r.loan_id
      AND i.status = 'pending';

    v_refund := round(v_should - coalesce(r.outstanding_principal, 0), 2);

    IF v_refund > 0.005 THEN
      UPDATE public."Club_Finances"
      SET balance = balance + v_refund
      WHERE club_name = r.club_short_name;

      PERFORM public.post_club_ledger(
        r.club_short_name,
        'adjustment',
        v_refund,
        format(
          'Loan principal restore — loan #%s (service-counter due bug over-collection)',
          r.loan_id
        ),
        jsonb_build_object(
          'repair', 'loan_due_process_no_overcharge',
          'loan_id', r.loan_id,
          'outstanding_was', r.outstanding_principal,
          'outstanding_should', v_should,
          'refund', v_refund
        ),
        v_season,
        NULL,
        false,
        false
      );

      UPDATE public.gpsl_bank_account
      SET loan_book_outstanding = loan_book_outstanding + v_refund,
          reserves = greatest(0, reserves - v_refund),
          updated_at = now()
      WHERE id = 1;
    END IF;

    UPDATE public.club_loans
    SET outstanding_principal = v_should,
        installments_paid = (
          SELECT count(*)::int
          FROM public.club_loan_installments i
          WHERE i.loan_id = r.loan_id AND i.status = 'paid'
        ),
        updated_at = now(),
        status = CASE WHEN v_should <= 0.005 THEN 'paid' ELSE 'active' END,
        closed_at = CASE
          WHEN v_should <= 0.005 THEN coalesce(closed_at, now())
          ELSE NULL
        END
    WHERE id = r.loan_id;
  END LOOP;
END;
$repair$;

GRANT EXECUTE ON FUNCTION public.club_loan_installment_is_due(bigint, integer, text, bigint, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_apply_principal_payment(bigint, numeric, text, bigint)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_settle_scheduled_installment(bigint)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_process_due_for_club(text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_process_my_due_installments()
  TO authenticated;

NOTIFY pgrst, 'reload schema';
