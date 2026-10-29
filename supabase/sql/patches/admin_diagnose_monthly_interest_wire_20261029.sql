-- Diagnose: is monthly interest wired into month lock? Did August fire?
-- Safe read-only.

SELECT 'settings' AS section,
       b.monthly_interest_enabled,
       b.monthly_balance_interest_pct,
       b.monthly_debt_interest_pct,
       b.monthly_debt_interest_bad_credit_pct
FROM public.gpsl_bank_account b
WHERE b.id = 1;

SELECT 'wired_in_month_lock' AS section,
       (position('competition_post_monthly_interest' IN pg_get_functiondef(
         'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
       )) > 0) AS interest_in_jobs,
       (to_regprocedure('public.competition_post_monthly_interest(bigint,text)') IS NOT NULL) AS fn_exists;

SELECT 'interest_rows_by_month' AS section,
       m.gpsl_month,
       count(*) AS clubs,
       count(*) FILTER (WHERE m.kind = 'credit') AS credit_n,
       count(*) FILTER (WHERE m.kind = 'debt') AS debt_n,
       sum(m.amount) FILTER (WHERE m.kind = 'credit') AS credit_total,
       sum(m.amount) FILTER (WHERE m.kind = 'debt') AS debt_total
FROM public.club_monthly_interest m
JOIN public.competition_seasons s ON s.id = m.season_id AND s.is_current
GROUP BY m.gpsl_month
ORDER BY m.gpsl_month;

SELECT 'august_ledger_sample' AS section,
       l.entry_type,
       count(*) AS n,
       sum(l.amount) AS total
FROM public.club_finance_ledger l
JOIN public.competition_seasons s ON s.id = l.season_id AND s.is_current
WHERE l.entry_type IN ('eos_balance_interest', 'eos_debt_interest')
  AND (
    coalesce(l.metadata->>'gpsl_month','') = 'august'
    OR coalesce(l.metadata->>'monthly','') = 'true'
    OR l.description ILIKE '%august%'
  )
GROUP BY l.entry_type;

SELECT 'august_calendar' AS section,
       c.gpsl_month, c.unlock_at, c.lock_at, c.locked
FROM public.competition_season_calendar c
JOIN public.competition_seasons s ON s.id = c.season_id AND s.is_current
WHERE lower(btrim(c.gpsl_month)) IN ('june','july','august')
ORDER BY c.unlock_at;

-- Snapshot coverage for August (needed for fair retro)
SELECT 'august_snapshots' AS section,
       count(DISTINCT club_short_name) AS clubs_with_snapshot,
       min(captured_at) AS first_snap,
       max(captured_at) AS last_snap
FROM public.club_finance_month_snapshots snap
JOIN public.competition_seasons s ON s.id = snap.season_id AND s.is_current
WHERE lower(btrim(snap.gpsl_month)) = 'august';
