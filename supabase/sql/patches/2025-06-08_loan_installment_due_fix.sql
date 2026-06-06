-- =============================================================================
-- Fix loan instalments pinned to Season 1 when future seasons do not exist yet.
-- Due matching now uses GPSL months elapsed since drawdown (instalment_no),
-- not (due_season_id, due_gpsl_month) alone.
-- Run after 2025-06-07_loan_interest_schedule.sql
-- =============================================================================

ALTER TABLE public.club_loan_installments
  ADD COLUMN IF NOT EXISTS due_season_offset integer NOT NULL DEFAULT 0
    CHECK (due_season_offset >= 0);

CREATE OR REPLACE FUNCTION public.competition_season_ordinal(p_season_id bigint)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.rn::integer
  FROM (
    SELECT id, row_number() OVER (ORDER BY id) AS rn
    FROM public.competition_seasons
  ) s
  WHERE s.id = p_season_id;
$$;

CREATE OR REPLACE FUNCTION public.competition_gpsl_month_from_sort(p_sort smallint)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_sort
    WHEN 1 THEN 'august'
    WHEN 2 THEN 'september'
    WHEN 3 THEN 'october'
    WHEN 4 THEN 'november'
    WHEN 5 THEN 'december'
    WHEN 6 THEN 'january'
    WHEN 7 THEN 'february'
    WHEN 8 THEN 'march'
    WHEN 9 THEN 'april'
    WHEN 10 THEN 'may'
    ELSE NULL
  END;
$$;

DROP FUNCTION IF EXISTS public.competition_resolve_gpsl_month_offset(bigint, text, integer);

CREATE OR REPLACE FUNCTION public.competition_resolve_gpsl_month_offset(
  p_base_season_id bigint,
  p_base_month text,
  p_months_ahead integer
)
RETURNS TABLE (
  due_season_id bigint,
  due_gpsl_month text,
  due_season_offset integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_base_sort smallint;
  v_target_sort integer;
  v_season_shift integer;
  v_month_sort smallint;
BEGIN
  v_base_sort := public.competition_gpsl_month_sort(p_base_month);
  IF v_base_sort IS NULL OR p_months_ahead IS NULL OR p_months_ahead < 1 THEN
    RETURN;
  END IF;

  v_target_sort := v_base_sort + p_months_ahead;
  v_season_shift := (v_target_sort - 1) / 10;
  v_month_sort := ((v_target_sort - 1) % 10) + 1;
  due_season_offset := v_season_shift;
  due_gpsl_month := public.competition_gpsl_month_from_sort(v_month_sort);

  SELECT s.id
  INTO due_season_id
  FROM public.competition_seasons s
  WHERE s.id >= p_base_season_id
  ORDER BY s.id
  OFFSET v_season_shift
  LIMIT 1;

  IF due_season_id IS NULL THEN
    due_season_id := p_base_season_id;
  END IF;

  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_loan_due_season_label(
  p_base_season_id bigint,
  p_season_offset integer
)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    (
      SELECT s.label
      FROM public.competition_seasons s
      WHERE s.id >= p_base_season_id
      ORDER BY s.id
      OFFSET greatest(p_season_offset, 0)
      LIMIT 1
    ),
    format('GPSL year +%s', greatest(p_season_offset, 0) + 1)
  );
$$;

CREATE OR REPLACE FUNCTION public.club_loan_gpsl_months_elapsed(
  p_loan_season_id bigint,
  p_drawdown_month text,
  p_current_season_id bigint,
  p_current_month text
)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_draw_sort smallint;
  v_cur_sort smallint;
  v_loan_ord integer;
  v_cur_ord integer;
BEGIN
  IF p_current_month IS NULL OR btrim(p_current_month) = '' THEN
    RETURN -1;
  END IF;

  v_draw_sort := public.competition_gpsl_month_sort(p_drawdown_month);
  v_cur_sort := public.competition_gpsl_month_sort(p_current_month);

  IF v_draw_sort IS NULL OR v_cur_sort IS NULL THEN
    RETURN -1;
  END IF;

  v_loan_ord := public.competition_season_ordinal(p_loan_season_id);
  v_cur_ord := public.competition_season_ordinal(p_current_season_id);

  IF v_loan_ord IS NULL OR v_cur_ord IS NULL THEN
    RETURN -1;
  END IF;

  RETURN (v_cur_ord - v_loan_ord) * 10 + (v_cur_sort - v_draw_sort);
END;
$function$;

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
      due_season_offset,
      due_gpsl_month,
      principal_due,
      interest_due,
      status
    )
    VALUES (
      p_loan_id,
      v_i::smallint,
      v_due.due_season_id,
      coalesce(v_due.due_season_offset, 0),
      v_due.due_gpsl_month,
      CASE WHEN v_i = v_months THEN v_last ELSE v_base END,
      0,
      'pending'
    );
  END LOOP;

  v_opening := round(p_principal, 2);

  FOR v_season IN
    SELECT
      i.due_season_offset,
      count(*)::integer AS inst_count,
      sum(i.principal_due)::numeric AS season_principal
    FROM public.club_loan_installments i
    WHERE i.loan_id = p_loan_id
    GROUP BY i.due_season_offset
    ORDER BY i.due_season_offset
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
          AND i.due_season_offset = v_season.due_season_offset
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

CREATE OR REPLACE FUNCTION public.club_loan_settle_scheduled_installment(p_installment_id bigint)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_inst record;
  v_loan record;
  v_total numeric;
  v_balance numeric;
  v_paid numeric := 0;
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
  v_season_label := public.club_loan_due_season_label(
    v_inst.loan_season_id,
    coalesce(v_inst.due_season_offset, 0)
  );

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
        v_season_label,
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

CREATE OR REPLACE FUNCTION public.club_loan_process_due_for_club(p_club text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_active_month text;
  v_elapsed integer;
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
  IF v_active_month IS NULL THEN
    RETURN jsonb_build_object('processed', 0, 'total_paid', 0, 'reason', 'no_active_gpsl_month');
  END IF;

  FOR v_inst IN
    SELECT i.*, l.season_id AS loan_season_id, l.drawdown_gpsl_month
    FROM public.club_loan_installments i
    JOIN public.club_loans l ON l.id = i.loan_id
    WHERE l.club_short_name = btrim(p_club)
      AND l.status = 'active'
      AND i.status = 'pending'
      AND l.drawdown_gpsl_month IS NOT NULL
      AND public.club_loan_gpsl_months_elapsed(
        l.season_id,
        l.drawdown_gpsl_month,
        v_season_id,
        v_active_month
      ) >= i.installment_no
    ORDER BY i.installment_no
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

DROP VIEW IF EXISTS public.club_loan_installments_public;

CREATE VIEW public.club_loan_installments_public
WITH (security_invoker = true)
AS
SELECT
  i.id,
  i.loan_id,
  i.installment_no,
  i.due_season_id,
  public.club_loan_due_season_label(l.season_id, coalesce(i.due_season_offset, 0)) AS due_season_label,
  i.due_season_offset,
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
WHERE l.club_short_name = public.my_club_shortname();

GRANT SELECT ON public.club_loan_installments_public TO authenticated;

-- Rebuild schedules that were never correctly paid (skip loans with any paid instalment).
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

NOTIFY pgrst, 'reload schema';
