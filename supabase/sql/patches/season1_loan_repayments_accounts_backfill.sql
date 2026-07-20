-- =============================================================================
-- Loan repayments on Season accounts (Season 1 backfill + Season 2+ fix)
--
-- Why Season 1 still shows ₿0 repayments with ₿100M drawdowns:
--   Monthly installment settlement often never ran in Season 1, so rows stay
--   pending (paid_amount = 0). An earlier paid-only backfill found nothing.
--
-- This patch:
--   A) Posts new principal/interest to installment due_season_id (Season 2+)
--   B) Retags existing installment-linked ledger rows to due_season_id
--   C) Reconstructs Season 1 dues from the installment SCHEDULE onto the ledger
--      (even when still pending), marks those installments paid, reduces
--      outstanding — NO Club_Finances debit (season already closed)
--   D) Re-snapshots Season 1 finance archive
--
-- Run in Supabase SQL Editor. Safe re-run.
-- Then hard-refresh finances_accounts.html?season=1
-- =============================================================================

-- ---------------------------------------------------------------------------
-- A) Fix apply helpers — ledger season = due season when installment known
-- ---------------------------------------------------------------------------

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

  v_due_season := NULL;
  IF p_installment_id IS NOT NULL THEN
    SELECT interest_due - interest_paid, due_season_id
    INTO v_inst_interest, v_due_season
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

  -- Prefer installment due season; else current season; else drawdown season
  IF v_due_season IS NOT NULL THEN
    v_ledger_season := v_due_season;
  ELSE
    SELECT id INTO v_ledger_season
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
    v_ledger_season := coalesce(v_ledger_season, v_loan.season_id);
  END IF;

  PERFORM public.post_club_ledger(
    v_loan.club_short_name,
    'loan_interest_payment',
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

  v_due_season := NULL;
  IF p_installment_id IS NOT NULL THEN
    SELECT due_season_id INTO v_due_season
    FROM public.club_loan_installments
    WHERE id = p_installment_id
      AND loan_id = p_loan_id;
  END IF;

  IF v_due_season IS NOT NULL THEN
    v_ledger_season := v_due_season;
  ELSE
    SELECT id INTO v_ledger_season
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
    v_ledger_season := coalesce(v_ledger_season, v_loan.season_id);
  END IF;

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
  SET reserves = reserves + v_pay,
      updated_at = now()
  WHERE id = 1;

  RETURN v_pay;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_loan_apply_interest_payment(bigint, numeric, text, bigint)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.club_loan_apply_principal_payment(bigint, numeric, text, bigint)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- B + C + D) Retag, backfill missing lines, re-archive Season 1
-- ---------------------------------------------------------------------------
DO $loan_accounts_fix$
DECLARE
  v_sid bigint;
  v_label text;
  v_retagged int := 0;
  v_principal int := 0;
  v_interest int := 0;
  v_archived int := 0;
  v_inst record;
  v_diag record;
  v_desc text;
  v_month_label text;
  v_season_label text;
  v_before int;
  v_after int;
  v_list text;
BEGIN
  -- Ensure loan entry types are allowed (union live + loan types)
  SELECT string_agg(quote_literal(t), ', ' ORDER BY t)
  INTO v_list
  FROM (
    SELECT DISTINCT entry_type AS t
    FROM public.competition_finance_ledger
    WHERE entry_type IS NOT NULL
    UNION
    SELECT unnest(ARRAY[
      'loan_drawdown',
      'loan_repayment_principal',
      'loan_interest_payment'
    ])
  ) u;

  IF v_list IS NOT NULL THEN
    EXECUTE format(
      'ALTER TABLE public.competition_finance_ledger DROP CONSTRAINT IF EXISTS competition_finance_ledger_entry_type_check'
    );
    EXECUTE format(
      'ALTER TABLE public.competition_finance_ledger ADD CONSTRAINT competition_finance_ledger_entry_type_check CHECK (entry_type IN (%s))',
      v_list
    );
  END IF;

  SELECT s.id, s.label INTO v_sid, v_label
  FROM public.competition_seasons s
  WHERE s.label IN ('1', 'Season 1')
  ORDER BY CASE WHEN s.label = '1' THEN 0 ELSE 1 END, s.id DESC
  LIMIT 1;

  -- B) Retag installment-linked loan rows onto due_season_id
  WITH updated AS (
    UPDATE public.competition_finance_ledger l
    SET season_id = i.due_season_id
    FROM public.club_loan_installments i
    WHERE l.entry_type IN ('loan_repayment_principal', 'loan_interest_payment')
      AND nullif(btrim(coalesce(l.metadata->>'installment_id', '')), '') IS NOT NULL
      AND (l.metadata->>'installment_id')::bigint = i.id
      AND i.due_season_id IS NOT NULL
      AND l.season_id IS DISTINCT FROM i.due_season_id
    RETURNING l.id
  )
  SELECT count(*)::int INTO v_retagged FROM updated;

  IF v_sid IS NULL THEN
    RAISE NOTICE 'Loan accounts fix: retagged=% (no Season 1 found)', v_retagged;
    RETURN;
  END IF;

  SELECT count(*)::int INTO v_before
  FROM public.competition_finance_ledger l
  WHERE l.season_id = v_sid
    AND l.entry_type IN ('loan_repayment_principal', 'loan_interest_payment');

  RAISE NOTICE 'Season % id=% — installment snapshot before backfill:', v_label, v_sid;
  FOR v_diag IN
    SELECT
      i.status,
      count(*)::int AS n,
      coalesce(sum(i.principal_due), 0) AS principal_due_sum,
      coalesce(sum(i.paid_amount), 0) AS paid_principal_sum,
      coalesce(sum(i.interest_due), 0) AS interest_due_sum,
      coalesce(sum(i.interest_paid), 0) AS interest_paid_sum
    FROM public.club_loan_installments i
    JOIN public.club_loans l ON l.id = i.loan_id
    WHERE i.due_season_id = v_sid
       OR (l.season_id = v_sid AND coalesce(i.due_season_offset, 0) = 0)
    GROUP BY i.status
    ORDER BY i.status
  LOOP
    RAISE NOTICE '  status=% count=% principal_due=₿% paid=₿% interest_due=₿% interest_paid=₿%',
      v_diag.status, v_diag.n, v_diag.principal_due_sum, v_diag.paid_principal_sum,
      v_diag.interest_due_sum, v_diag.interest_paid_sum;
  END LOOP;

  -- C) Reconstruct Season 1 installment dues onto the ledger.
  -- Monthly settlement often never ran in Season 1, so paid_amount stays 0 while
  -- principal_due/interest_due are set. We post ledger lines for every S1-due
  -- installment that lacks a matching ledger row, mark them paid, and reduce
  -- outstanding — WITHOUT debiting Club_Finances (season already closed; cash
  -- was never taken at the time). Season 2 will not re-collect these rows.
  FOR v_inst IN
    SELECT
      i.id AS installment_id,
      i.loan_id,
      i.installment_no,
      i.due_season_id,
      i.due_gpsl_month,
      i.due_season_offset,
      i.principal_due,
      i.interest_due,
      i.paid_amount,
      i.interest_paid,
      i.paid_at,
      i.status,
      l.club_short_name,
      l.repayment_months,
      l.season_id AS loan_season_id,
      l.outstanding_principal
    FROM public.club_loan_installments i
    JOIN public.club_loans l ON l.id = i.loan_id
    WHERE i.status IN ('pending', 'paid')
      AND (
        i.due_season_id = v_sid
        OR (
          l.season_id = v_sid
          AND coalesce(i.due_season_offset, 0) = 0
        )
      )
      AND (
        coalesce(i.principal_due, 0) > 0.005
        OR coalesce(i.interest_due, 0) > 0.005
        OR coalesce(i.paid_amount, 0) > 0.005
        OR coalesce(i.interest_paid, 0) > 0.005
      )
    ORDER BY l.club_short_name, i.loan_id, i.installment_no
  LOOP
    v_month_label := public.competition_gpsl_month_label(v_inst.due_gpsl_month);
    BEGIN
      v_season_label := public.club_loan_due_season_label(
        v_inst.loan_season_id,
        coalesce(v_inst.due_season_offset, 0)
      );
    EXCEPTION
      WHEN undefined_function THEN
        SELECT coalesce(s.label, v_inst.due_season_id::text)
        INTO v_season_label
        FROM public.competition_seasons s
        WHERE s.id = v_inst.due_season_id;
    END;

    -- Principal: prefer amount already paid; else scheduled due
    IF greatest(coalesce(v_inst.paid_amount, 0), coalesce(v_inst.principal_due, 0)) > 0.005
       AND NOT EXISTS (
         SELECT 1
         FROM public.competition_finance_ledger x
         WHERE x.entry_type = 'loan_repayment_principal'
           AND (
             (
               nullif(btrim(coalesce(x.metadata->>'installment_id', '')), '') IS NOT NULL
               AND (x.metadata->>'installment_id')::bigint = v_inst.installment_id
             )
             OR (
               x.club_short_name = v_inst.club_short_name
               AND x.season_id = v_sid
               AND nullif(btrim(coalesce(x.metadata->>'loan_id', '')), '') IS NOT NULL
               AND (x.metadata->>'loan_id')::bigint = v_inst.loan_id
               AND coalesce(x.description, '') ILIKE
                 ('%inst ' || v_inst.installment_no::text || '/%')
             )
           )
       )
    THEN
      v_desc := format(
        'Scheduled loan repayment — %s %s (inst %s/%s, loan #%s) [Season 1 accounts backfill]',
        coalesce(v_month_label, v_inst.due_gpsl_month),
        coalesce(v_season_label, ''),
        v_inst.installment_no,
        coalesce(v_inst.repayment_months, 20),
        v_inst.loan_id
      );

      INSERT INTO public.competition_finance_ledger (
        season_id, fixture_id, club_short_name, entry_type, amount,
        description, metadata, created_at
      )
      VALUES (
        v_sid,
        NULL,
        v_inst.club_short_name,
        'loan_repayment_principal',
        -abs(greatest(coalesce(v_inst.paid_amount, 0), coalesce(v_inst.principal_due, 0))),
        v_desc,
        jsonb_build_object(
          'loan_id', v_inst.loan_id,
          'installment_id', v_inst.installment_id,
          'accounts_backfill', true,
          'season1_schedule_reconstruct', true
        ),
        coalesce(v_inst.paid_at, now())
      );
      v_principal := v_principal + 1;
    END IF;

    -- Interest
    IF greatest(coalesce(v_inst.interest_paid, 0), coalesce(v_inst.interest_due, 0)) > 0.005
       AND NOT EXISTS (
         SELECT 1
         FROM public.competition_finance_ledger x
         WHERE x.entry_type = 'loan_interest_payment'
           AND (
             (
               nullif(btrim(coalesce(x.metadata->>'installment_id', '')), '') IS NOT NULL
               AND (x.metadata->>'installment_id')::bigint = v_inst.installment_id
             )
             OR (
               x.club_short_name = v_inst.club_short_name
               AND x.season_id = v_sid
               AND nullif(btrim(coalesce(x.metadata->>'loan_id', '')), '') IS NOT NULL
               AND (x.metadata->>'loan_id')::bigint = v_inst.loan_id
               AND coalesce(x.description, '') ILIKE
                 ('%inst ' || v_inst.installment_no::text || '/%')
             )
           )
       )
    THEN
      v_desc := format(
        'Loan interest — %s %s (inst %s/%s, loan #%s) [Season 1 accounts backfill]',
        coalesce(v_month_label, v_inst.due_gpsl_month),
        coalesce(v_season_label, ''),
        v_inst.installment_no,
        coalesce(v_inst.repayment_months, 20),
        v_inst.loan_id
      );

      INSERT INTO public.competition_finance_ledger (
        season_id, fixture_id, club_short_name, entry_type, amount,
        description, metadata, created_at
      )
      VALUES (
        v_sid,
        NULL,
        v_inst.club_short_name,
        'loan_interest_payment',
        -abs(greatest(coalesce(v_inst.interest_paid, 0), coalesce(v_inst.interest_due, 0))),
        v_desc,
        jsonb_build_object(
          'loan_id', v_inst.loan_id,
          'installment_id', v_inst.installment_id,
          'accounts_backfill', true,
          'season1_schedule_reconstruct', true
        ),
        coalesce(v_inst.paid_at, now())
      );
      v_interest := v_interest + 1;
    END IF;

    -- Align installment + outstanding so Season 2 does not re-collect
    IF v_inst.status = 'pending' THEN
      UPDATE public.club_loan_installments
      SET paid_amount = greatest(coalesce(paid_amount, 0), coalesce(principal_due, 0)),
          interest_paid = greatest(coalesce(interest_paid, 0), coalesce(interest_due, 0)),
          status = 'paid',
          paid_at = coalesce(paid_at, now())
      WHERE id = v_inst.installment_id
        AND status = 'pending';

      UPDATE public.club_loans
      SET outstanding_principal = greatest(
            0,
            round(outstanding_principal - coalesce(v_inst.principal_due, 0), 2)
          ),
          installments_paid = least(
            coalesce(repayment_months, 20),
            coalesce(installments_paid, 0) + 1
          ),
          updated_at = now(),
          status = CASE
            WHEN outstanding_principal - coalesce(v_inst.principal_due, 0) <= 0.005
              THEN 'paid'
            ELSE status
          END,
          closed_at = CASE
            WHEN outstanding_principal - coalesce(v_inst.principal_due, 0) <= 0.005
              THEN coalesce(closed_at, now())
            ELSE closed_at
          END
      WHERE id = v_inst.loan_id
        AND status = 'active';
    END IF;
  END LOOP;

  -- D) Re-snapshot Season 1 archive
  IF to_regprocedure('public.competition_archive_club_finances_for_season(bigint)') IS NOT NULL THEN
    v_archived := public.competition_archive_club_finances_for_season(v_sid);
  END IF;

  SELECT count(*)::int INTO v_after
  FROM public.competition_finance_ledger l
  WHERE l.season_id = v_sid
    AND l.entry_type IN ('loan_repayment_principal', 'loan_interest_payment');

  RAISE NOTICE
    'Loan accounts fix Season % (id=%): retagged=% principal_inserted=% interest_inserted=% ledger_loan_lines=%→% clubs_archived=%',
    v_label, v_sid, v_retagged, v_principal, v_interest, v_before, v_after, v_archived;

  RAISE NOTICE '--- Season 1 loan ledger by club ---';
  FOR v_diag IN
    SELECT
      l.club_short_name AS club,
      count(*) FILTER (WHERE l.entry_type = 'loan_repayment_principal') AS principal_lines,
      coalesce(sum(abs(l.amount)) FILTER (WHERE l.entry_type = 'loan_repayment_principal'), 0) AS principal_total,
      count(*) FILTER (WHERE l.entry_type = 'loan_interest_payment') AS interest_lines,
      coalesce(sum(abs(l.amount)) FILTER (WHERE l.entry_type = 'loan_interest_payment'), 0) AS interest_total
    FROM public.competition_finance_ledger l
    WHERE l.season_id = v_sid
      AND l.entry_type IN ('loan_repayment_principal', 'loan_interest_payment')
    GROUP BY l.club_short_name
    ORDER BY l.club_short_name
  LOOP
    RAISE NOTICE '% | principal lines=% ₿% | interest lines=% ₿%',
      v_diag.club,
      v_diag.principal_lines,
      v_diag.principal_total,
      v_diag.interest_lines,
      v_diag.interest_total;
  END LOOP;
END;
$loan_accounts_fix$;

-- Easy grid in SQL editor (Season 1 loan lines after backfill)
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
