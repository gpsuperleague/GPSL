-- =============================================================================
-- Restore underpaid S1 loans (AJX / LEV / NMU)
--
-- After reverse patches these clubs have 0 paid / ₿50M outstanding, but June S2
-- expects 10 paid / ₿25M. Cash was already refunded to them — claw it back and
-- mark instalments 1..expected as paid WITHOUT posting new loan_repayment rows
-- (Season 1 accounts should already reflect those payments; settle would also
-- risk dumping S1 dues onto Season 2).
--
-- Safe re-run: only touches pending rows with installment_no <= expected.
-- =============================================================================

DO $restore$
DECLARE
  v_season_id bigint;
  v_as_of text := 'june';
  v_loan record;
  v_inst record;
  v_expected int;
  v_prin numeric;
  v_int numeric;
  v_total numeric;
  v_loan_prin numeric;
  v_loan_int numeric;
  v_loan_total numeric;
  v_marked int := 0;
  v_loans int := 0;
  v_cash numeric := 0;
BEGIN
  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'no current season';
  END IF;

  v_as_of := coalesce(
    public.competition_active_gpsl_month(v_season_id, now()),
    public.club_loan_as_of_gpsl_month(v_season_id),
    'june'
  );

  FOR v_loan IN
    SELECT l.*
    FROM public.club_loans l
    WHERE l.status IN ('active', 'paid')
      AND l.drawdown_gpsl_month IS NOT NULL
    ORDER BY l.club_short_name, l.id
  LOOP
    v_expected := public.club_loan_expected_paid_count(
      v_loan.season_id,
      v_loan.drawdown_gpsl_month,
      coalesce(v_loan.repayment_months, 20),
      v_season_id,
      v_as_of
    );

    IF v_expected <= 0 THEN
      CONTINUE;
    END IF;

    -- Already at or above expected → skip
    IF (
      SELECT count(*) FROM public.club_loan_installments i
      WHERE i.loan_id = v_loan.id AND i.status = 'paid'
    ) >= v_expected THEN
      CONTINUE;
    END IF;

    v_loan_prin := 0;
    v_loan_int := 0;
    v_loans := v_loans + 1;

    FOR v_inst IN
      SELECT *
      FROM public.club_loan_installments i
      WHERE i.loan_id = v_loan.id
        AND i.status = 'pending'
        AND i.installment_no <= v_expected
      ORDER BY i.installment_no
    LOOP
      v_prin := round(greatest(coalesce(v_inst.principal_due, 0), 0), 2);
      v_int := round(greatest(coalesce(v_inst.interest_due, 0), 0), 2);

      UPDATE public.club_loan_installments
      SET status = 'paid',
          paid_amount = v_prin,
          interest_paid = v_int,
          paid_at = coalesce(paid_at, now())
      WHERE id = v_inst.id;

      v_loan_prin := v_loan_prin + v_prin;
      v_loan_int := v_loan_int + v_int;
      v_marked := v_marked + 1;
    END LOOP;

    v_loan_total := round(v_loan_prin + v_loan_int, 2);

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

    IF v_loan_total > 0.005 THEN
      -- Claw back the erroneous refund (balance only; no loan_repayment lines)
      UPDATE public."Club_Finances"
      SET balance = balance - v_loan_total
      WHERE club_name = v_loan.club_short_name;

      UPDATE public.gpsl_bank_account
      SET loan_book_outstanding = greatest(0, loan_book_outstanding - v_loan_prin),
          reserves = reserves + v_loan_total,
          updated_at = now()
      WHERE id = 1;

      PERFORM public.post_club_ledger(
        v_loan.club_short_name,
        'adjustment',
        -v_loan_total,
        format(
          'S1 loan schedule restore — claw back refund (loan #%s, %s inst, as-of %s)',
          v_loan.id,
          v_expected,
          v_as_of
        ),
        jsonb_build_object(
          'repair', 'loan_restore_underpaid_s1',
          'loan_id', v_loan.id,
          'expected_paid', v_expected,
          'principal', v_loan_prin,
          'interest', v_loan_int,
          'as_of_gpsl_month', v_as_of
        ),
        v_season_id,
        NULL,
        false,
        false
      );

      v_cash := v_cash + v_loan_total;
    END IF;
  END LOOP;

  RAISE NOTICE 'restore_underpaid: loans=%, instalments_marked=%, cash_clawed=%',
    v_loans, v_marked, v_cash;
END;
$restore$;

-- Verify
WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
)
SELECT
  l.id AS loan_id,
  l.club_short_name,
  l.drawdown_gpsl_month,
  l.outstanding_principal,
  (SELECT count(*) FROM public.club_loan_installments i
    WHERE i.loan_id = l.id AND i.status = 'paid') AS paid_rows,
  public.club_loan_expected_paid_count(
    l.season_id, l.drawdown_gpsl_month, coalesce(l.repayment_months, 20),
    c.season_id, 'june'
  ) AS expected_paid,
  CASE
    WHEN (SELECT count(*) FROM public.club_loan_installments i
            WHERE i.loan_id = l.id AND i.status = 'paid')
         = public.club_loan_expected_paid_count(
             l.season_id, l.drawdown_gpsl_month, coalesce(l.repayment_months, 20),
             c.season_id, 'june'
           )
      THEN 'OK'
    ELSE 'CHECK'
  END AS status
FROM public.club_loans l
CROSS JOIN cur c
WHERE l.status IN ('active', 'paid')
ORDER BY l.club_short_name, l.id;
