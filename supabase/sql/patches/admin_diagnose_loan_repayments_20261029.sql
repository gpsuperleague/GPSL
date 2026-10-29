-- =============================================================================
-- All club loans — have repayments started?
-- Read-only. Paste result grids back.
-- =============================================================================

-- Context: current season / loan as-of month
SELECT
  s.id AS season_id,
  s.label AS season_label,
  public.competition_active_gpsl_month(s.id, now()) AS active_gpsl_month,
  public.club_loan_as_of_gpsl_month(s.id) AS loan_as_of_month,
  (
    SELECT m.gpsl_month
    FROM public.competition_season_calendar m
    WHERE m.season_id = s.id AND m.lock_at IS NOT NULL AND m.lock_at <= now()
    ORDER BY m.sort_order DESC
    LIMIT 1
  ) AS last_locked_month
FROM public.competition_seasons s
WHERE s.is_current
ORDER BY s.id DESC
LIMIT 1;

-- 1) Every loan + repayment progress
SELECT
  l.id AS loan_id,
  l.club_short_name AS club,
  c.owner,
  l.status,
  l.drawdown_gpsl_month,
  public.competition_season_ordinal(l.season_id) AS draw_season,
  l.principal_drawn,
  l.outstanding_principal,
  coalesce(l.repayment_months, 20) AS repayment_months,
  coalesce(l.installments_paid, 0) AS installments_paid_col,
  (
    SELECT count(*)::int
    FROM public.club_loan_installments i
    WHERE i.loan_id = l.id AND i.status = 'paid'
  ) AS paid_installments,
  (
    SELECT count(*)::int
    FROM public.club_loan_installments i
    WHERE i.loan_id = l.id AND i.status = 'pending'
  ) AS pending_installments,
  (
    SELECT count(*)::int
    FROM public.club_loan_installments i
    WHERE i.loan_id = l.id AND i.status = 'skipped'
  ) AS skipped_installments,
  public.club_loan_expected_paid_count(
    l.season_id,
    l.drawdown_gpsl_month,
    coalesce(l.repayment_months, 20),
    (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1),
    public.club_loan_as_of_gpsl_month(
      (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
    )
  ) AS expected_paid_now,
  CASE
    WHEN (
      SELECT count(*) FROM public.club_loan_installments i
      WHERE i.loan_id = l.id AND i.status = 'paid'
    ) > 0 THEN 'YES — repayments started'
    WHEN l.status = 'paid' THEN 'YES — loan fully paid'
    WHEN public.club_loan_expected_paid_count(
      l.season_id, l.drawdown_gpsl_month, coalesce(l.repayment_months, 20),
      (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1),
      public.club_loan_as_of_gpsl_month(
        (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
      )
    ) > 0 THEN 'NO — should have started (behind)'
    ELSE 'NOT YET DUE'
  END AS repayment_read,
  (
    SELECT min(i.due_gpsl_month)
    FROM public.club_loan_installments i
    WHERE i.loan_id = l.id AND i.status = 'pending'
  ) AS next_pending_month,
  (
    SELECT max(i.due_gpsl_month)
    FROM public.club_loan_installments i
    WHERE i.loan_id = l.id AND i.status = 'paid'
  ) AS last_paid_month,
  (
    SELECT coalesce(sum(i.paid_amount), 0)
    FROM public.club_loan_installments i
    WHERE i.loan_id = l.id AND i.status = 'paid'
  ) AS total_paid_amount
FROM public.club_loans l
LEFT JOIN public."Clubs" c ON c."ShortName" = l.club_short_name
WHERE l.status IN ('active', 'paid', 'defaulted')
ORDER BY
  CASE
    WHEN (
      SELECT count(*) FROM public.club_loan_installments i
      WHERE i.loan_id = l.id AND i.status = 'paid'
    ) = 0
    AND public.club_loan_expected_paid_count(
      l.season_id, l.drawdown_gpsl_month, coalesce(l.repayment_months, 20),
      (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1),
      public.club_loan_as_of_gpsl_month(
        (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
      )
    ) > 0 THEN 0
    WHEN (
      SELECT count(*) FROM public.club_loan_installments i
      WHERE i.loan_id = l.id AND i.status = 'paid'
    ) = 0 THEN 1
    ELSE 2
  END,
  l.club_short_name,
  l.id;

-- 2) Summary counts
SELECT
  count(*) FILTER (WHERE l.status = 'active') AS active_loans,
  count(*) FILTER (WHERE l.status = 'paid') AS fully_paid_loans,
  count(*) FILTER (
    WHERE l.status = 'active'
      AND EXISTS (
        SELECT 1 FROM public.club_loan_installments i
        WHERE i.loan_id = l.id AND i.status = 'paid'
      )
  ) AS active_with_repayments_started,
  count(*) FILTER (
    WHERE l.status = 'active'
      AND NOT EXISTS (
        SELECT 1 FROM public.club_loan_installments i
        WHERE i.loan_id = l.id AND i.status = 'paid'
      )
  ) AS active_with_zero_repayments,
  count(*) FILTER (
    WHERE l.status = 'active'
      AND NOT EXISTS (
        SELECT 1 FROM public.club_loan_installments i
        WHERE i.loan_id = l.id AND i.status = 'paid'
      )
      AND public.club_loan_expected_paid_count(
        l.season_id, l.drawdown_gpsl_month, coalesce(l.repayment_months, 20),
        (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1),
        public.club_loan_as_of_gpsl_month(
          (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
        )
      ) > 0
  ) AS active_behind_schedule
FROM public.club_loans l;

-- 3) Clubs behind: next few pending installments
SELECT
  l.club_short_name AS club,
  l.id AS loan_id,
  i.installment_no,
  i.due_gpsl_month,
  i.due_season_offset,
  i.principal_due,
  i.interest_due,
  i.status
FROM public.club_loans l
JOIN public.club_loan_installments i ON i.loan_id = l.id
WHERE l.status = 'active'
  AND i.status = 'pending'
  AND NOT EXISTS (
    SELECT 1 FROM public.club_loan_installments x
    WHERE x.loan_id = l.id AND x.status = 'paid'
  )
  AND public.club_loan_expected_paid_count(
    l.season_id, l.drawdown_gpsl_month, coalesce(l.repayment_months, 20),
    (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1),
    public.club_loan_as_of_gpsl_month(
      (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
    )
  ) > 0
ORDER BY l.club_short_name, i.installment_no
LIMIT 80;

-- 4) Recent loan repayment ledger hits (club accounts)
SELECT
  fl.club_short_name AS club,
  fl.entry_type,
  fl.amount,
  fl.description,
  fl.created_at,
  fl.metadata->>'gpsl_month' AS gpsl_month
FROM public.competition_finance_ledger fl
WHERE fl.entry_type ILIKE '%loan%repay%'
   OR fl.entry_type IN (
     'loan_repayment_principal',
     'loan_repayment_interest',
     'loan_interest',
     'loan_principal'
   )
ORDER BY fl.created_at DESC
LIMIT 40;
