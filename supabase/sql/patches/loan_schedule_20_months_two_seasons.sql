-- =============================================================================
-- Loan schedule: 20 GPSL months = two seasons (Aug–May × 2 when drawn in Aug)
--
-- Rules:
--   • Drawn in August → first installment is August (10 + 10 across two seasons)
--   • Drawn mid-season (e.g. January) → first installment is the NEXT GPSL month
--     (February), still 20 months total
--   • Interest is pre-calculated per season-bucket on opening principal
--   • Early settle skips pending installments and clears remaining interest
--   • Season accounts only ever show that season’s due installments / payments
--
-- Also repairs Season 1 accounts pollution (full 20 months posted onto Season 1)
-- for August Season 1 drawdowns: keep 10 principal (+ interest) lines per loan.
--
-- Run in Supabase SQL Editor after prior loan patches. Safe-ish re-run.
-- Then hard-refresh Service counter, League loans, and finances_accounts?season=1
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Month offset: allow 0 (same month as drawdown)
-- ---------------------------------------------------------------------------

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
  v_base_ord integer;
BEGIN
  v_base_sort := public.competition_gpsl_month_sort(p_base_month);
  IF v_base_sort IS NULL OR p_months_ahead IS NULL OR p_months_ahead < 0 THEN
    RETURN;
  END IF;

  v_target_sort := v_base_sort + p_months_ahead;
  v_season_shift := (v_target_sort - 1) / 10;
  v_month_sort := ((v_target_sort - 1) % 10) + 1;
  due_season_offset := v_season_shift;
  due_gpsl_month := public.competition_gpsl_month_from_sort(v_month_sort);

  -- Resolve due season by ordinal so missing future seasons do not pin to base
  v_base_ord := public.competition_season_ordinal(p_base_season_id);
  IF v_base_ord IS NOT NULL THEN
    SELECT s.id
    INTO due_season_id
    FROM public.competition_seasons s
    WHERE public.competition_season_ordinal(s.id) = v_base_ord + v_season_shift
    ORDER BY s.id
    LIMIT 1;
  END IF;

  IF due_season_id IS NULL THEN
    SELECT s.id
    INTO due_season_id
    FROM public.competition_seasons s
    WHERE s.id >= p_base_season_id
    ORDER BY s.id
    OFFSET v_season_shift
    LIMIT 1;
  END IF;

  -- Last resort: always set a season id (column is NOT NULL); repair retags later
  IF due_season_id IS NULL THEN
    due_season_id := p_base_season_id;
  END IF;

  RETURN NEXT;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2) Generate 20 installments with correct first due month + interest
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_loan_first_months_ahead(p_drawdown_month text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN lower(btrim(coalesce(p_drawdown_month, ''))) IN ('august', 'aug') THEN 0
    ELSE 1
  END;
$$;

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
  v_first_ahead integer;
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
  v_first_ahead := public.club_loan_first_months_ahead(p_drawdown_month);

  FOR v_i IN 1..v_months LOOP
    SELECT * INTO v_due
    FROM public.competition_resolve_gpsl_month_offset(
      p_base_season_id,
      p_drawdown_month,
      v_first_ahead + v_i - 1
    );

    IF v_due.due_gpsl_month IS NULL THEN
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

  -- Interest:  rate% on opening principal of each season-offset bucket,
  -- split evenly across that bucket's installments (pre-calculated at take).
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

-- ---------------------------------------------------------------------------
-- 3) Early settle: skip pending and clear remaining interest
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

  SELECT coalesce(cf."Balance", 0)
  INTO v_balance
  FROM public."Club_Finances" cf
  WHERE cf."ShortName" = v_loan.club_short_name;

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

-- ---------------------------------------------------------------------------
-- 4) League loans view — show pre-calculated interest + remaining
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.club_loans_league_public;

CREATE VIEW public.club_loans_league_public
WITH (security_invoker = false)
AS
SELECT
  l.id,
  l.club_short_name,
  c."Club" AS club_name,
  l.season_id,
  l.principal_drawn,
  l.outstanding_principal,
  l.interest_rate_pct,
  l.status,
  l.repayment_months,
  l.drawdown_gpsl_month,
  public.competition_gpsl_month_label(l.drawdown_gpsl_month) AS drawdown_gpsl_month_label,
  coalesce((
    SELECT round(sum(i.interest_due), 2)
    FROM public.club_loan_installments i
    WHERE i.loan_id = l.id
  ), 0) AS interest_total_scheduled,
  coalesce((
    SELECT round(sum(i.interest_paid), 2)
    FROM public.club_loan_installments i
    WHERE i.loan_id = l.id
  ), 0) AS interest_paid_total,
  coalesce((
    SELECT round(sum(greatest(0, i.interest_due - i.interest_paid)), 2)
    FROM public.club_loan_installments i
    WHERE i.loan_id = l.id
      AND i.status = 'pending'
  ), 0) AS interest_remaining,
  coalesce((
    SELECT count(*)::int
    FROM public.club_loan_installments i
    WHERE i.loan_id = l.id
      AND i.status = 'pending'
  ), 0) AS installments_remaining,
  l.created_at,
  l.updated_at,
  l.closed_at
FROM public.club_loans l
JOIN public."Clubs" c ON c."ShortName" = l.club_short_name;

GRANT SELECT ON public.club_loans_league_public TO authenticated;

-- Keep club_loans_public interest fields in sync if view exists
DO $$
BEGIN
  IF to_regclass('public.club_loans_public') IS NOT NULL THEN
    DROP VIEW IF EXISTS public.club_loans_public;
    EXECUTE $v$
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
        coalesce((
          SELECT round(sum(i.interest_due), 2)
          FROM public.club_loan_installments i
          WHERE i.loan_id = l.id
        ), 0) AS interest_total_scheduled,
        coalesce((
          SELECT round(sum(i.interest_paid), 2)
          FROM public.club_loan_installments i
          WHERE i.loan_id = l.id
        ), 0) AS interest_paid_total,
        coalesce((
          SELECT round(sum(greatest(0, i.interest_due - i.interest_paid)), 2)
          FROM public.club_loan_installments i
          WHERE i.loan_id = l.id
            AND i.status = 'pending'
        ), 0) AS interest_remaining,
        (
          SELECT round(sum(i.principal_due + i.interest_due), 2)
          FROM public.club_loan_installments i
          WHERE i.loan_id = l.id AND i.status = 'pending'
        ) AS pending_schedule_total,
        (
          SELECT i.due_gpsl_month
          FROM public.club_loan_installments i
          WHERE i.loan_id = l.id AND i.status = 'pending'
          ORDER BY i.due_season_offset, public.competition_gpsl_month_sort(i.due_gpsl_month), i.installment_no
          LIMIT 1
        ) AS next_due_gpsl_month,
        (
          SELECT public.competition_gpsl_month_label(i.due_gpsl_month)
          FROM public.club_loan_installments i
          WHERE i.loan_id = l.id AND i.status = 'pending'
          ORDER BY i.due_season_offset, public.competition_gpsl_month_sort(i.due_gpsl_month), i.installment_no
          LIMIT 1
        ) AS next_due_gpsl_month_label,
        (
          SELECT round(i.principal_due + i.interest_due, 2)
          FROM public.club_loan_installments i
          WHERE i.loan_id = l.id AND i.status = 'pending'
          ORDER BY i.due_season_offset, public.competition_gpsl_month_sort(i.due_gpsl_month), i.installment_no
          LIMIT 1
        ) AS next_installment_due,
        l.created_at,
        l.updated_at,
        l.closed_at
      FROM public.club_loans l
      WHERE l.club_short_name = public.my_club_shortname()
    $v$;
    GRANT SELECT ON public.club_loans_public TO authenticated;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 5) Repair due_season_id from offset; rebuild August S1 schedules; fix accounts
-- ---------------------------------------------------------------------------

DO $repair$
DECLARE
  v_s1 bigint;
  v_s1_label text;
  v_loan record;
  v_inst record;
  v_due record;
  v_base_ord integer;
  v_sid bigint;
  v_desc text;
  v_month_label text;
  v_season_label text;
  v_principal_lines int := 0;
  v_interest_lines int := 0;
  v_rebuilt int := 0;
  v_retagged int := 0;
  v_deleted int := 0;
  v_archived int := 0;
  v_out numeric;
BEGIN
  SELECT s.id, s.label INTO v_s1, v_s1_label
  FROM public.competition_seasons s
  WHERE s.label IN ('1', 'Season 1')
  ORDER BY CASE WHEN s.label = '1' THEN 0 ELSE 1 END, s.id DESC
  LIMIT 1;

  -- 5a) Retag due_season_id from due_season_offset for every installment
  FOR v_inst IN
    SELECT i.id, i.loan_id, i.due_season_offset, l.season_id AS loan_season_id
    FROM public.club_loan_installments i
    JOIN public.club_loans l ON l.id = i.loan_id
  LOOP
    v_base_ord := public.competition_season_ordinal(v_inst.loan_season_id);
    v_sid := NULL;
    IF v_base_ord IS NOT NULL THEN
      SELECT s.id INTO v_sid
      FROM public.competition_seasons s
      WHERE public.competition_season_ordinal(s.id) = v_base_ord + coalesce(v_inst.due_season_offset, 0)
      ORDER BY s.id
      LIMIT 1;
    END IF;
    IF v_sid IS NULL THEN
      SELECT s.id INTO v_sid
      FROM public.competition_seasons s
      WHERE s.id >= v_inst.loan_season_id
      ORDER BY s.id
      OFFSET coalesce(v_inst.due_season_offset, 0)
      LIMIT 1;
    END IF;
    IF v_sid IS NOT NULL THEN
      UPDATE public.club_loan_installments
      SET due_season_id = v_sid
      WHERE id = v_inst.id
        AND due_season_id IS DISTINCT FROM v_sid;
      IF FOUND THEN
        v_retagged := v_retagged + 1;
      END IF;
    END IF;
  END LOOP;

  -- 5b) Delete invented / mis-tagged Season 1 loan payment lines
  IF v_s1 IS NOT NULL THEN
    WITH d AS (
      DELETE FROM public.competition_finance_ledger l
      WHERE l.season_id = v_s1
        AND l.entry_type IN ('loan_repayment_principal', 'loan_interest_payment')
        AND (
          coalesce((l.metadata->>'accounts_backfill')::boolean, false)
          OR coalesce((l.metadata->>'season1_schedule_reconstruct')::boolean, false)
          OR coalesce(l.description, '') ILIKE '%Season 1 accounts backfill%'
          OR coalesce(l.description, '') ILIKE '%Season 2%'
          OR coalesce(l.description, '') ILIKE '%Season 3%'
          OR coalesce(l.description, '') ILIKE '%GPSL year +%'
        )
      RETURNING 1
    )
    SELECT count(*)::int INTO v_deleted FROM d;
  END IF;

  -- 5c) Rebuild August Season 1 active loans onto true 10+10 schedule
  FOR v_loan IN
    SELECT l.*
    FROM public.club_loans l
    WHERE v_s1 IS NOT NULL
      AND l.season_id = v_s1
      AND lower(btrim(coalesce(l.drawdown_gpsl_month, ''))) IN ('august', 'aug')
      AND l.status IN ('active', 'paid')
  LOOP
    -- Rebuild schedule (interest pre-calculated again)
    PERFORM public.club_loan_generate_installments(
      v_loan.id,
      v_loan.principal_drawn,
      v_loan.season_id,
      v_loan.drawdown_gpsl_month,
      coalesce(v_loan.repayment_months, 20)::smallint,
      v_loan.interest_rate_pct
    );

    -- Season 1 closed: mark first-season (offset 0) installments paid without cash
    UPDATE public.club_loan_installments i
    SET paid_amount = i.principal_due,
        interest_paid = i.interest_due,
        status = 'paid',
        paid_at = coalesce(i.paid_at, now())
    WHERE i.loan_id = v_loan.id
      AND coalesce(i.due_season_offset, 0) = 0;

    -- Second season stays pending (interest remains scheduled until paid / early settle)
    UPDATE public.club_loan_installments i
    SET paid_amount = 0,
        interest_paid = 0,
        status = 'pending',
        paid_at = NULL
    WHERE i.loan_id = v_loan.id
      AND coalesce(i.due_season_offset, 0) > 0;

    SELECT coalesce(sum(i.principal_due), 0)
    INTO v_out
    FROM public.club_loan_installments i
    WHERE i.loan_id = v_loan.id
      AND i.status = 'pending';

    UPDATE public.club_loans
    SET outstanding_principal = v_out,
        installments_paid = (
          SELECT count(*)::int
          FROM public.club_loan_installments i
          WHERE i.loan_id = v_loan.id AND i.status = 'paid'
        ),
        status = CASE WHEN v_out <= 0.005 THEN 'paid' ELSE 'active' END,
        closed_at = CASE WHEN v_out <= 0.005 THEN coalesce(closed_at, now()) ELSE NULL END,
        updated_at = now()
    WHERE id = v_loan.id;

    -- Post Season 1 accounts lines for offset-0 only (10 equal payments per loan)
    FOR v_inst IN
      SELECT *
      FROM public.club_loan_installments i
      WHERE i.loan_id = v_loan.id
        AND coalesce(i.due_season_offset, 0) = 0
      ORDER BY i.installment_no
    LOOP
      v_month_label := public.competition_gpsl_month_label(v_inst.due_gpsl_month);
      v_season_label := public.club_loan_due_season_label(v_loan.season_id, 0);

      IF coalesce(v_inst.paid_amount, 0) > 0.005 THEN
        v_desc := format(
          'Scheduled loan repayment — %s %s (inst %s/%s, loan #%s)',
          coalesce(v_month_label, v_inst.due_gpsl_month),
          coalesce(v_season_label, v_s1_label),
          v_inst.installment_no,
          coalesce(v_loan.repayment_months, 20),
          v_loan.id
        );
        INSERT INTO public.competition_finance_ledger (
          season_id, fixture_id, club_short_name, entry_type, amount,
          description, metadata, created_at
        )
        VALUES (
          v_s1,
          NULL,
          v_loan.club_short_name,
          'loan_repayment_principal',
          -abs(v_inst.paid_amount),
          v_desc,
          jsonb_build_object(
            'loan_id', v_loan.id,
            'installment_id', v_inst.id,
            'accounts_backfill', true,
            'season1_first_season_only', true
          ),
          coalesce(v_inst.paid_at, now())
        );
        v_principal_lines := v_principal_lines + 1;
      END IF;

      IF coalesce(v_inst.interest_paid, 0) > 0.005 THEN
        v_desc := format(
          'Loan interest — %s %s (inst %s/%s, loan #%s)',
          coalesce(v_month_label, v_inst.due_gpsl_month),
          coalesce(v_season_label, v_s1_label),
          v_inst.installment_no,
          coalesce(v_loan.repayment_months, 20),
          v_loan.id
        );
        INSERT INTO public.competition_finance_ledger (
          season_id, fixture_id, club_short_name, entry_type, amount,
          description, metadata, created_at
        )
        VALUES (
          v_s1,
          NULL,
          v_loan.club_short_name,
          'loan_interest_payment',
          -abs(v_inst.interest_paid),
          v_desc,
          jsonb_build_object(
            'loan_id', v_loan.id,
            'installment_id', v_inst.id,
            'accounts_backfill', true,
            'season1_first_season_only', true
          ),
          coalesce(v_inst.paid_at, now())
        );
        v_interest_lines := v_interest_lines + 1;
      END IF;
    END LOOP;

    v_rebuilt := v_rebuilt + 1;
  END LOOP;

  -- 5d) Retag remaining installment-linked ledger rows to true due_season_id
  WITH updated AS (
    UPDATE public.competition_finance_ledger l
    SET season_id = i.due_season_id
    FROM public.club_loan_installments i
    WHERE l.entry_type IN ('loan_repayment_principal', 'loan_interest_payment')
      AND nullif(btrim(coalesce(l.metadata->>'installment_id', '')), '') IS NOT NULL
      AND (l.metadata->>'installment_id')::bigint = i.id
      AND i.due_season_id IS NOT NULL
      AND l.season_id IS DISTINCT FROM i.due_season_id
      AND NOT coalesce((l.metadata->>'season1_first_season_only')::boolean, false)
    RETURNING l.id
  )
  SELECT count(*)::int + v_retagged INTO v_retagged FROM updated;

  IF v_s1 IS NOT NULL
     AND to_regprocedure('public.competition_archive_club_finances_for_season(bigint)') IS NOT NULL THEN
    v_archived := public.competition_archive_club_finances_for_season(v_s1);
  END IF;

  RAISE NOTICE
    'Loan 20-month repair: due_season retags=% deleted_s1_bad_lines=% rebuilt_aug_s1_loans=% s1_principal_lines=% s1_interest_lines=% archived=%',
    v_retagged, v_deleted, v_rebuilt, v_principal_lines, v_interest_lines, v_archived;
END;
$repair$;

NOTIFY pgrst, 'reload schema';

-- Sanity: Season 1 loan lines should be ~10 principal + ~10 interest per loan
SELECT
  l.club_short_name,
  l.entry_type,
  count(*) AS lines,
  round(sum(abs(l.amount)), 2) AS total
FROM public.competition_finance_ledger l
JOIN public.competition_seasons s ON s.id = l.season_id
WHERE s.label IN ('1', 'Season 1')
  AND l.entry_type IN ('loan_repayment_principal', 'loan_interest_payment')
GROUP BY l.club_short_name, l.entry_type
ORDER BY l.club_short_name, l.entry_type;
