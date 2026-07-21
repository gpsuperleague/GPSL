-- =============================================================================
-- READ-ONLY loan diagnostic — Season 2 June over-collection
--
-- Run in Supabase SQL Editor. Does NOT change any data.
-- Paste the full result set(s) back so we can fix once with evidence.
-- =============================================================================

-- A) Calendar / as-of (what the server thinks "now" is)
WITH cur AS (
  SELECT id AS season_id, label, is_current, status
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
)
SELECT
  'A_as_of' AS section,
  c.season_id,
  c.label AS season_label,
  public.competition_season_ordinal(c.season_id) AS season_ordinal,
  c.status,
  public.competition_active_gpsl_month(c.season_id, now()) AS active_gpsl_month,
  public.club_loan_as_of_gpsl_month(c.season_id) AS loan_as_of_month,
  (
    SELECT m.gpsl_month
    FROM public.competition_season_calendar m
    WHERE m.season_id = c.season_id
      AND m.lock_at IS NOT NULL AND m.lock_at <= now()
    ORDER BY m.sort_order DESC
    LIMIT 1
  ) AS last_locked_any_month,
  (
    SELECT m.unlock_at
    FROM public.competition_season_calendar m
    WHERE m.season_id = c.season_id AND m.gpsl_month = 'august'
    LIMIT 1
  ) AS s2_august_unlock_at,
  now() AS db_now
FROM cur c;

-- B) Active loans + expected vs actual paid
WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
)
SELECT
  'B_loans' AS section,
  l.id AS loan_id,
  l.club_short_name,
  l.season_id AS draw_season_id,
  public.competition_season_ordinal(l.season_id) AS draw_season_ord,
  public.competition_season_ordinal(c.season_id) AS current_season_ord,
  l.drawdown_gpsl_month,
  l.principal_drawn,
  l.outstanding_principal,
  l.installments_paid,
  l.repayment_months,
  l.status,
  public.club_loan_as_of_gpsl_month(c.season_id) AS as_of,
  public.club_loan_expected_paid_count(
    l.season_id,
    l.drawdown_gpsl_month,
    coalesce(l.repayment_months, 20),
    c.season_id,
    public.club_loan_as_of_gpsl_month(c.season_id)
  ) AS expected_paid_using_as_of,
  -- Hardcoded June: what SHOULD be true in Season 2 soft months
  public.club_loan_expected_paid_count(
    l.season_id,
    l.drawdown_gpsl_month,
    coalesce(l.repayment_months, 20),
    c.season_id,
    'june'
  ) AS expected_paid_if_june,
  (SELECT count(*) FROM public.club_loan_installments i
    WHERE i.loan_id = l.id AND i.status = 'paid') AS actual_paid_rows,
  (SELECT count(*) FROM public.club_loan_installments i
    WHERE i.loan_id = l.id AND i.status = 'pending') AS actual_pending_rows,
  (SELECT coalesce(sum(i.principal_due), 0) FROM public.club_loan_installments i
    WHERE i.loan_id = l.id AND i.status = 'pending') AS pending_principal_sum,
  CASE
    WHEN lower(coalesce(l.drawdown_gpsl_month, '')) IN ('august', 'aug') THEN 25000000
    WHEN lower(coalesce(l.drawdown_gpsl_month, '')) IN ('september', 'sep') THEN 30000000
    ELSE NULL
  END AS target_outstanding_june_s2
FROM public.club_loans l
CROSS JOIN cur c
WHERE l.status IN ('active', 'paid')
ORDER BY l.club_short_name, l.id;

-- C) Per-instalment grid (the smoking gun — which # are paid vs should be)
WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
),
loans AS (
  SELECT l.*
  FROM public.club_loans l
  WHERE l.status IN ('active', 'paid')
)
SELECT
  'C_installments' AS section,
  l.id AS loan_id,
  l.club_short_name,
  l.drawdown_gpsl_month,
  i.installment_no,
  i.due_gpsl_month,
  i.due_season_id,
  i.due_season_offset,
  i.status,
  i.principal_due,
  i.interest_due,
  i.paid_amount,
  i.interest_paid,
  i.paid_at,
  public.club_loan_expected_paid_count(
    l.season_id, l.drawdown_gpsl_month, coalesce(l.repayment_months, 20),
    c.season_id, 'june'
  ) AS expected_cutoff_if_june,
  CASE
    WHEN i.status = 'paid'
     AND i.installment_no > public.club_loan_expected_paid_count(
       l.season_id, l.drawdown_gpsl_month, coalesce(l.repayment_months, 20),
       c.season_id, 'june'
     ) THEN 'OVERPAID_VS_JUNE'
    WHEN i.status = 'pending'
     AND i.installment_no <= public.club_loan_expected_paid_count(
       l.season_id, l.drawdown_gpsl_month, coalesce(l.repayment_months, 20),
       c.season_id, 'june'
     ) THEN 'UNDERPAID_VS_JUNE'
    ELSE 'OK_VS_JUNE'
  END AS diagnosis_vs_june
FROM loans l
JOIN public.club_loan_installments i ON i.loan_id = l.id
CROSS JOIN cur c
ORDER BY l.id, i.installment_no;

-- D) Season 2 ledger loan rows (phantom accounts posts)
WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
)
SELECT
  'D_s2_ledger' AS section,
  l.club_short_name,
  l.entry_type,
  l.gpsl_month,
  count(*) AS rows,
  round(sum(l.amount), 2) AS total_amount,
  min(l.created_at) AS first_at,
  max(l.created_at) AS last_at
FROM public.competition_finance_ledger l
CROSS JOIN cur c
WHERE l.season_id = c.season_id
  AND l.entry_type IN (
    'loan_repayment_principal',
    'loan_interest_payment',
    'loan_drawdown',
    'adjustment'
  )
GROUP BY l.club_short_name, l.entry_type, l.gpsl_month
ORDER BY l.club_short_name, l.entry_type, l.gpsl_month;

-- E) Which process_due / expected functions are deployed (names only + whether expected exists)
SELECT
  'E_functions' AS section,
  p.proname,
  pg_get_function_identity_arguments(p.oid) AS args,
  length(p.prosrc) AS src_chars,
  (p.prosrc ILIKE '%club_loan_expected_paid_count%') AS uses_expected_paid,
  (p.prosrc ILIKE '%june%' OR p.prosrc ILIKE '%july%') AS mentions_june_july,
  (p.prosrc ILIKE '%installment_no%') AS mentions_installment_no
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'club_loan_as_of_gpsl_month',
    'club_loan_expected_paid_count',
    'club_loan_installment_is_due',
    'club_loan_installment_is_due_by_no',
    'club_loan_process_due_for_club',
    'club_loan_process_my_due_installments',
    'club_loan_reconcile_expected_schedule',
    'club_loan_calendar_month_sort',
    'club_loan_first_months_ahead'
  )
ORDER BY p.proname;

-- F) Dry-run: what process_due WOULD collect right now (no settle)
WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
),
asof AS (
  SELECT c.season_id, public.club_loan_as_of_gpsl_month(c.season_id) AS as_of
  FROM cur c
)
SELECT
  'F_would_collect' AS section,
  l.club_short_name,
  l.id AS loan_id,
  i.installment_no,
  i.due_gpsl_month,
  i.principal_due,
  i.interest_due,
  a.as_of,
  public.club_loan_expected_paid_count(
    l.season_id, l.drawdown_gpsl_month, coalesce(l.repayment_months, 20),
    a.season_id, a.as_of
  ) AS expected_cutoff,
  CASE
    WHEN to_regprocedure('public.club_loan_installment_is_due_by_no(bigint,text,integer,integer,bigint,text)') IS NOT NULL
    THEN public.club_loan_installment_is_due_by_no(
      l.season_id, l.drawdown_gpsl_month, coalesce(l.repayment_months, 20),
      i.installment_no, a.season_id, a.as_of
    )
    ELSE NULL
  END AS due_by_no
FROM public.club_loans l
JOIN public.club_loan_installments i ON i.loan_id = l.id AND i.status = 'pending'
CROSS JOIN asof a
WHERE l.status = 'active'
  AND l.drawdown_gpsl_month IS NOT NULL
  AND i.installment_no <= public.club_loan_expected_paid_count(
    l.season_id, l.drawdown_gpsl_month, coalesce(l.repayment_months, 20),
    a.season_id, a.as_of
  )
ORDER BY l.id, i.installment_no;
