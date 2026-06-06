-- =============================================================================
-- Central Bank loans — 5% annual interest per GPSL season on opening balance
-- Principal: equal instalments over 20 GPSL months (10 per season).
-- Interest: 5% on opening principal each season, split across that season's
-- instalments. Ledger: loan_repayment_principal + loan_interest_payment.
-- Run after 2025-06-05_loan_repayment_schedule.sql
-- =============================================================================

ALTER TABLE public.club_loan_installments
  ADD COLUMN IF NOT EXISTS interest_due numeric(14, 2) NOT NULL DEFAULT 0
    CHECK (interest_due >= 0),
  ADD COLUMN IF NOT EXISTS interest_paid numeric(14, 2) NOT NULL DEFAULT 0
    CHECK (interest_paid >= 0);

CREATE OR REPLACE FUNCTION public.club_loan_generate_installments(
  p_loan_id bigint,
  p_principal numeric,
  p_base_season_id bigint,
  p_drawdown_month text,
  p_months smallint DEFAULT 20,
  p_interest_rate_pct numeric DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_months smallint := coalesce(p_months, 20);
  v_rate numeric;
  v_base numeric;
  v_last numeric;
  v_i integer;
  v_due record;
  v_opening numeric;
  v_season_interest numeric;
  v_season_principal numeric;
  v_inst_count integer;
  v_int_base numeric;
  v_int_last numeric;
  v_int_assigned numeric;
  v_season record;
  v_row record;
BEGIN
  SELECT coalesce(p_interest_rate_pct, l.interest_rate_pct, 5)
  INTO v_rate
  FROM public.club_loans l
  WHERE l.id = p_loan_id;

  IF v_rate IS NULL THEN
    v_rate := 5;
  END IF;

  DELETE FROM public.club_loan_installments WHERE loan_id = p_loan_id;

  v_base := round(p_principal / v_months, 2);
  v_last := round(p_principal - (v_base * (v_months - 1)), 2);

  FOR v_i IN 1..v_months LOOP
    SELECT * INTO v_due
    FROM public.competition_resolve_gpsl_month_offset(
      p_base_season_id,
      p_drawdown_month,
      v_i
    );

    IF v_due.due_season_id IS NULL OR v_due.due_gpsl_month IS NULL THEN
      RAISE EXCEPTION 'Could not resolve GPSL month for installment %', v_i;
    END IF;

    INSERT INTO public.club_loan_installments (
      loan_id,
      installment_no,
      due_season_id,
      due_gpsl_month,
      principal_due,
      interest_due,
      status
    )
    VALUES (
      p_loan_id,
      v_i::smallint,
      v_due.due_season_id,
      v_due.due_gpsl_month,
      CASE WHEN v_i = v_months THEN v_last ELSE v_base END,
      0,
      'pending'
    );
  END LOOP;

  v_opening := round(p_principal, 2);

  FOR v_season IN
    SELECT
      i.due_season_id,
      count(*)::integer AS inst_count,
      sum(i.principal_due)::numeric AS season_principal
    FROM public.club_loan_installments i
    WHERE i.loan_id = p_loan_id
    GROUP BY i.due_season_id
    ORDER BY i.due_season_id
  LOOP
    v_season_interest := round(v_opening * v_rate / 100, 2);
    v_inst_count := v_season.inst_count;
    v_season_principal := v_season.season_principal;

    IF v_season_interest > 0 AND v_inst_count > 0 THEN
      v_int_base := round(v_season_interest / v_inst_count, 2);
      v_int_last := round(v_season_interest - (v_int_base * (v_inst_count - 1)), 2);
      v_int_assigned := 0;

      FOR v_row IN
        SELECT i.id, i.installment_no
        FROM public.club_loan_installments i
        WHERE i.loan_id = p_loan_id
          AND i.due_season_id = v_season.due_season_id
        ORDER BY i.installment_no
      LOOP
        v_int_assigned := v_int_assigned + 1;
        UPDATE public.club_loan_installments
        SET interest_due = CASE
          WHEN v_int_assigned = v_inst_count THEN v_int_last
          ELSE v_int_base
        END
        WHERE id = v_row.id;
      END LOOP;
    END IF;

    v_opening := greatest(0, round(v_opening - v_season_principal, 2));
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_loan_apply_interest_payment(
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
  v_inst_interest numeric;
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

  IF p_installment_id IS NOT NULL THEN
    SELECT interest_due - interest_paid
    INTO v_inst_interest
    FROM public.club_loan_installments
    WHERE id = p_installment_id
      AND loan_id = p_loan_id
      AND status = 'pending';

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Installment not found';
    END IF;

    v_pay := least(round(coalesce(p_amount, 0)::numeric, 2), greatest(v_inst_interest, 0));
  ELSE
    v_pay := round(coalesce(p_amount, 0)::numeric, 2);
  END IF;

  IF v_pay <= 0 THEN
    RETURN 0;
  END IF;

  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_loan.club_short_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Club_Finances row missing';
  END IF;

  IF v_balance < v_pay THEN
    RAISE EXCEPTION 'Insufficient balance to pay loan interest % (balance %)', v_pay, v_balance;
  END IF;

  v_desc := coalesce(
    p_description,
    format('Loan interest payment (loan #%s)', v_loan.id)
  );

  PERFORM public.post_club_ledger(
    v_loan.club_short_name,
    'loan_interest_payment',
    -v_pay,
    v_desc,
    jsonb_build_object(
      'loan_id', v_loan.id,
      'installment_id', p_installment_id
    ),
    v_loan.season_id,
    NULL,
    true,
    true
  );

  IF p_installment_id IS NOT NULL THEN
    UPDATE public.club_loan_installments
    SET interest_paid = interest_paid + v_pay,
        paid_at = CASE
          WHEN paid_amount >= principal_due
            AND interest_paid + v_pay >= interest_due THEN now()
          ELSE paid_at
        END,
        status = CASE
          WHEN paid_amount >= principal_due
            AND interest_paid + v_pay >= interest_due THEN 'paid'
          ELSE status
        END
    WHERE id = p_installment_id
      AND loan_id = p_loan_id;
  END IF;

  UPDATE public.gpsl_bank_account
  SET reserves = reserves + v_pay,
      updated_at = now()
  WHERE id = 1;

  RETURN v_pay;
END;
$function$;

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
  v_desc text;
  v_months smallint;
BEGIN
  SELECT
    i.*,
    l.club_short_name,
    l.repayment_months,
    l.id AS loan_id
  INTO v_inst
  FROM public.club_loan_installments i
  JOIN public.club_loans l ON l.id = i.loan_id
  WHERE i.id = p_installment_id
    AND i.status = 'pending'
    AND l.status = 'active'
  FOR UPDATE OF i, l;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pending installment not found';
  END IF;

  v_total := round(v_inst.principal_due + coalesce(v_inst.interest_due, 0), 2);

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

  v_desc := format(
    'Scheduled loan repayment — %s %s (inst %s/%s, loan #%s)',
    public.competition_gpsl_month_label(v_inst.due_gpsl_month),
    (SELECT label FROM public.competition_seasons WHERE id = v_inst.due_season_id),
    v_inst.installment_no,
    v_months,
    v_inst.loan_id
  );

  v_paid := v_paid + public.club_loan_apply_principal_payment(
    v_inst.loan_id,
    v_inst.principal_due,
    v_desc,
    p_installment_id
  );

  IF coalesce(v_inst.interest_due, 0) > 0 THEN
    v_paid := v_paid + public.club_loan_apply_interest_payment(
      v_inst.loan_id,
      v_inst.interest_due,
      format(
        'Loan interest — %s %s (inst %s/%s, loan #%s)',
        public.competition_gpsl_month_label(v_inst.due_gpsl_month),
        (SELECT label FROM public.competition_seasons WHERE id = v_inst.due_season_id),
        v_inst.installment_no,
        v_months,
        v_inst.loan_id
      ),
      p_installment_id
    );
  ELSE
    UPDATE public.club_loan_installments
    SET status = CASE
          WHEN paid_amount >= principal_due THEN 'paid'
          ELSE status
        END,
        paid_at = CASE
          WHEN paid_amount >= principal_due THEN now()
          ELSE paid_at
        END
    WHERE id = p_installment_id;
  END IF;

  UPDATE public.club_loans
  SET installments_paid = installments_paid + 1,
      updated_at = now()
  WHERE id = v_inst.loan_id
    AND EXISTS (
      SELECT 1
      FROM public.club_loan_installments i
      WHERE i.id = p_installment_id
        AND i.status = 'paid'
    );

  RETURN v_paid;
END;
$function$;

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

  v_pay := least(round(coalesce(p_amount, 0)::numeric, 2), v_loan.outstanding_principal);
  IF v_pay <= 0 THEN
    RETURN 0;
  END IF;

  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_loan.club_short_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Club_Finances row missing';
  END IF;

  IF v_balance < v_pay THEN
    RAISE EXCEPTION 'Insufficient balance to repay % (balance %)', v_pay, v_balance;
  END IF;

  v_desc := coalesce(
    p_description,
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
    v_loan.season_id,
    NULL,
    true,
    true
  );

  UPDATE public.club_loans
  SET outstanding_principal = outstanding_principal - v_pay,
      updated_at = now(),
      installments_paid = installments_paid + CASE
        WHEN p_installment_id IS NOT NULL THEN 0
        ELSE 0
      END,
      status = CASE
        WHEN outstanding_principal - v_pay <= 0 THEN 'paid'
        ELSE 'active'
      END,
      closed_at = CASE
        WHEN outstanding_principal - v_pay <= 0 THEN now()
        ELSE closed_at
      END
  WHERE id = p_loan_id;

  IF p_installment_id IS NOT NULL THEN
    SELECT * INTO v_inst
    FROM public.club_loan_installments
    WHERE id = p_installment_id
      AND loan_id = p_loan_id;

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

    IF v_loan.outstanding_principal - v_pay <= 0 THEN
      UPDATE public.club_loan_installments
      SET status = 'skipped'
      WHERE loan_id = p_loan_id
        AND status = 'pending';
    END IF;
  END IF;

  IF v_loan.outstanding_principal - v_pay <= 0 AND p_installment_id IS NULL THEN
    UPDATE public.club_loan_installments
    SET status = 'skipped'
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

CREATE OR REPLACE FUNCTION public.club_loan_process_due_for_club(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_active_month text;
  v_active_sort smallint;
  v_inst record;
  v_paid numeric := 0;
  v_count int := 0;
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
    RETURN jsonb_build_object('processed', 0, 'total_paid', 0);
  END IF;

  v_active_month := public.competition_active_gpsl_month(v_season_id, now());
  v_active_sort := coalesce(public.competition_gpsl_month_sort(v_active_month), 10);

  FOR v_inst IN
    SELECT i.*
    FROM public.club_loan_installments i
    JOIN public.club_loans l ON l.id = i.loan_id
    WHERE l.club_short_name = btrim(p_club)
      AND l.status = 'active'
      AND i.status = 'pending'
      AND (
        i.due_season_id < v_season_id
        OR (
          i.due_season_id = v_season_id
          AND public.competition_gpsl_month_sort(i.due_gpsl_month) <= v_active_sort
        )
      )
    ORDER BY i.due_season_id, public.competition_gpsl_month_sort(i.due_gpsl_month), i.installment_no
  LOOP
    BEGIN
      v_paid := v_paid + public.club_loan_settle_scheduled_installment(v_inst.id);
      v_count := v_count + 1;
    EXCEPTION
      WHEN OTHERS THEN
        NULL;
    END;
  END LOOP;

  RETURN jsonb_build_object('processed', v_count, 'total_paid', v_paid);
END;
$function$;

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
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
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

DROP VIEW IF EXISTS public.club_loan_installments_public;

CREATE VIEW public.club_loan_installments_public
WITH (security_invoker = true)
AS
SELECT
  i.id,
  i.loan_id,
  i.installment_no,
  i.due_season_id,
  s.label AS due_season_label,
  i.due_gpsl_month,
  public.competition_gpsl_month_label(i.due_gpsl_month) AS due_gpsl_month_label,
  i.principal_due,
  i.interest_due,
  round(i.principal_due + i.interest_due, 2) AS total_due,
  i.status,
  i.paid_amount,
  i.interest_paid,
  i.paid_at,
  l.club_short_name,
  l.repayment_months,
  l.interest_rate_pct
FROM public.club_loan_installments i
JOIN public.club_loans l ON l.id = i.loan_id
JOIN public.competition_seasons s ON s.id = i.due_season_id
WHERE l.club_short_name = public.my_club_shortname();

GRANT SELECT ON public.club_loan_installments_public TO authenticated;

DROP VIEW IF EXISTS public.club_loans_public;

CREATE VIEW public.club_loans_public
WITH (security_invoker = true)
AS
SELECT
  l.id,
  l.club_short_name,
  l.season_id,
  l.principal_drawn,
  l.outstanding_principal,
  l.interest_rate_pct,
  l.status,
  l.repayment_months,
  l.drawdown_gpsl_month,
  public.competition_gpsl_month_label(l.drawdown_gpsl_month) AS drawdown_gpsl_month_label,
  l.installments_paid,
  (
    SELECT round(sum(i.principal_due + i.interest_due), 2)
    FROM public.club_loan_installments i
    WHERE i.loan_id = l.id AND i.status = 'pending'
  ) AS pending_schedule_total,
  (
    SELECT i.due_gpsl_month
    FROM public.club_loan_installments i
    WHERE i.loan_id = l.id AND i.status = 'pending'
    ORDER BY i.due_season_id, public.competition_gpsl_month_sort(i.due_gpsl_month), i.installment_no
    LIMIT 1
  ) AS next_due_gpsl_month,
  (
    SELECT public.competition_gpsl_month_label(i.due_gpsl_month)
    FROM public.club_loan_installments i
    WHERE i.loan_id = l.id AND i.status = 'pending'
    ORDER BY i.due_season_id, public.competition_gpsl_month_sort(i.due_gpsl_month), i.installment_no
    LIMIT 1
  ) AS next_due_gpsl_month_label,
  (
    SELECT round(i.principal_due + i.interest_due, 2)
    FROM public.club_loan_installments i
    WHERE i.loan_id = l.id AND i.status = 'pending'
    ORDER BY i.due_season_id, public.competition_gpsl_month_sort(i.due_gpsl_month), i.installment_no
    LIMIT 1
  ) AS next_installment_due,
  l.created_at,
  l.updated_at,
  l.closed_at
FROM public.club_loans l
WHERE l.club_short_name = public.my_club_shortname();

GRANT SELECT ON public.club_loans_public TO authenticated;

-- Regenerate schedules for active loans with no paid instalments yet (principal-only backfill).
DO $repair$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT l.id, l.principal_drawn, l.season_id, l.drawdown_gpsl_month, l.repayment_months, l.interest_rate_pct
    FROM public.club_loans l
    WHERE l.status = 'active'
      AND l.drawdown_gpsl_month IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.club_loan_installments i
        WHERE i.loan_id = l.id AND i.status = 'paid'
      )
  LOOP
    PERFORM public.club_loan_generate_installments(
      r.id,
      r.principal_drawn,
      r.season_id,
      r.drawdown_gpsl_month,
      coalesce(r.repayment_months, 20)::smallint,
      r.interest_rate_pct
    );
  END LOOP;
END;
$repair$;

DO $process$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT DISTINCT l.club_short_name AS club
    FROM public.club_loans l
    JOIN public.club_loan_installments i ON i.loan_id = l.id
    WHERE l.status = 'active'
      AND i.status = 'pending'
  LOOP
    PERFORM public.club_loan_process_due_for_club(r.club);
  END LOOP;
END;
$process$;

GRANT EXECUTE ON FUNCTION public.club_loan_apply_interest_payment(bigint, numeric, text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_loan_settle_scheduled_installment(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
