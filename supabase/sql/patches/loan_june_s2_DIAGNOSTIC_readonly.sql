-- =============================================================================
-- READ-ONLY loan diagnostic — single JSON result (Supabase-friendly)
-- Does NOT change any data. Paste the json back.
-- =============================================================================

WITH cur AS (
  SELECT
    s.id AS season_id,
    s.label AS season_label,
    s.status,
    public.competition_season_ordinal(s.id) AS season_ordinal
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1
),
asof AS (
  SELECT
    c.*,
    public.competition_active_gpsl_month(c.season_id, now()) AS active_gpsl_month,
    public.club_loan_as_of_gpsl_month(c.season_id) AS loan_as_of_month,
    (
      SELECT m.gpsl_month
      FROM public.competition_season_calendar m
      WHERE m.season_id = c.season_id
        AND m.lock_at IS NOT NULL
        AND m.lock_at <= now()
      ORDER BY m.sort_order DESC
      LIMIT 1
    ) AS last_locked_any_month,
    (
      SELECT m.unlock_at
      FROM public.competition_season_calendar m
      WHERE m.season_id = c.season_id AND m.gpsl_month = 'august'
      LIMIT 1
    ) AS s2_august_unlock_at
  FROM cur c
),
loan_rows AS (
  SELECT
    l.id AS loan_id,
    l.club_short_name,
    l.season_id AS draw_season_id,
    public.competition_season_ordinal(l.season_id) AS draw_season_ord,
    a.season_ordinal AS current_season_ord,
    l.drawdown_gpsl_month,
    l.principal_drawn,
    l.outstanding_principal,
    l.installments_paid,
    l.repayment_months,
    l.status,
    a.loan_as_of_month AS as_of,
    public.club_loan_expected_paid_count(
      l.season_id, l.drawdown_gpsl_month, coalesce(l.repayment_months, 20),
      a.season_id, a.loan_as_of_month
    ) AS expected_paid_using_as_of,
    public.club_loan_expected_paid_count(
      l.season_id, l.drawdown_gpsl_month, coalesce(l.repayment_months, 20),
      a.season_id, 'june'
    ) AS expected_paid_if_june,
    (SELECT count(*)::int FROM public.club_loan_installments i
      WHERE i.loan_id = l.id AND i.status = 'paid') AS actual_paid_rows,
    (SELECT count(*)::int FROM public.club_loan_installments i
      WHERE i.loan_id = l.id AND i.status = 'pending') AS actual_pending_rows,
    (SELECT coalesce(sum(i.principal_due), 0)
      FROM public.club_loan_installments i
      WHERE i.loan_id = l.id AND i.status = 'pending') AS pending_principal_sum,
    CASE
      WHEN lower(coalesce(l.drawdown_gpsl_month, '')) IN ('august', 'aug') THEN 25000000
      WHEN lower(coalesce(l.drawdown_gpsl_month, '')) IN ('september', 'sep') THEN 30000000
      ELSE NULL
    END AS target_outstanding_june_s2
  FROM public.club_loans l
  CROSS JOIN asof a
  WHERE l.status IN ('active', 'paid')
),
overpaid AS (
  SELECT
    l.loan_id,
    l.club_short_name,
    l.drawdown_gpsl_month,
    i.installment_no,
    i.due_gpsl_month,
    i.due_season_offset,
    i.status,
    i.principal_due,
    i.interest_due,
    i.paid_amount,
    i.interest_paid,
    l.expected_paid_if_june
  FROM loan_rows l
  JOIN public.club_loan_installments i ON i.loan_id = l.loan_id
  WHERE i.status IN ('paid', 'skipped')
    AND i.installment_no > l.expected_paid_if_june
),
ledger_s2 AS (
  SELECT
    l.club_short_name,
    l.entry_type,
    coalesce(l.metadata->>'gpsl_month', l.metadata->>'month', '(none)') AS gpsl_month,
    count(*)::int AS rows,
    round(sum(l.amount), 2) AS total_amount
  FROM public.competition_finance_ledger l
  CROSS JOIN asof a
  WHERE l.season_id = a.season_id
    AND l.entry_type IN (
      'loan_repayment_principal',
      'loan_interest_payment',
      'loan_drawdown',
      'adjustment'
    )
  GROUP BY 1, 2, 3
),
funcs AS (
  SELECT
    p.proname,
    pg_get_function_identity_arguments(p.oid) AS args,
    length(p.prosrc) AS src_chars,
    (p.prosrc ILIKE '%club_loan_expected_paid_count%') AS uses_expected_paid,
    (p.prosrc ILIKE '%june%') AS mentions_june,
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
)
SELECT jsonb_pretty(jsonb_build_object(
  'A_as_of', (SELECT to_jsonb(a) || jsonb_build_object('db_now', now()) FROM asof a),
  'B_loans', coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.club_short_name, r.loan_id) FROM loan_rows r), '[]'::jsonb),
  'C_overpaid_vs_june_only', coalesce((SELECT jsonb_agg(to_jsonb(o) ORDER BY o.loan_id, o.installment_no) FROM overpaid o), '[]'::jsonb),
  'C_overpaid_count', (SELECT count(*) FROM overpaid),
  'D_s2_ledger', coalesce((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.club_short_name, d.entry_type) FROM ledger_s2 d), '[]'::jsonb),
  'E_functions', coalesce((SELECT jsonb_agg(to_jsonb(f) ORDER BY f.proname) FROM funcs f), '[]'::jsonb),
  'expect_in_june_s2', jsonb_build_object(
    'aug_draw_paid', 10,
    'aug_draw_outstanding', 25000000,
    'sep_draw_paid', 8,
    'sep_draw_outstanding', 30000000
  )
)) AS diagnostic;
