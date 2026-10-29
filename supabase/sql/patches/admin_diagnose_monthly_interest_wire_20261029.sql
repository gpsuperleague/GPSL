-- Diagnose: monthly interest wired? months paid? August status?
-- Single result set. Safe read-only.

SELECT 0 AS sort_key, 'settings' AS section,
       b.monthly_interest_enabled::text AS a,
       b.monthly_balance_interest_pct::text AS b,
       b.monthly_debt_interest_pct::text AS c,
       coalesce(b.monthly_debt_interest_bad_credit_pct::text, '') AS d
FROM public.gpsl_bank_account b WHERE b.id = 1

UNION ALL
SELECT 1, 'wired_in_month_lock',
       (position('competition_post_monthly_interest' IN pg_get_functiondef(
         'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
       )) > 0)::text,
       (to_regprocedure('public.competition_post_monthly_interest(bigint,text)') IS NOT NULL)::text,
       (position('club_balance_snapshot_gpsl_month' IN pg_get_functiondef(
         'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
       )) > 0)::text,
       ''

UNION ALL
SELECT 2, 'interest_rows', m.gpsl_month, count(*)::text,
       count(*) FILTER (WHERE m.kind IN ('credit','balance'))::text,
       count(*) FILTER (WHERE m.kind = 'debt')::text
FROM public.club_monthly_interest m
JOIN public.competition_seasons s ON s.id = m.season_id AND s.is_current
GROUP BY m.gpsl_month

UNION ALL
SELECT 3, 'calendar', c.gpsl_month,
       to_char(timezone('Europe/London', c.unlock_at), 'YYYY-MM-DD HH24:MI'),
       to_char(timezone('Europe/London', c.lock_at), 'YYYY-MM-DD HH24:MI'),
       CASE WHEN c.lock_at <= now() THEN 'past_lock' ELSE 'open' END
FROM public.competition_season_calendar c
JOIN public.competition_seasons s ON s.id = c.season_id AND s.is_current
WHERE lower(btrim(c.gpsl_month)) IN ('june','july','august','september')

UNION ALL
SELECT 4, 'lock_jobs', lower(j.gpsl_month),
       left(string_agg(DISTINCT j.job_key, ','), 80),
       to_char(timezone('Europe/London', min(j.ran_at)), 'YYYY-MM-DD HH24:MI'),
       count(*)::text
FROM public.competition_season_calendar_jobs j
JOIN public.competition_seasons s ON s.id = j.season_id AND s.is_current
WHERE j.gpsl_month IS NOT NULL
  AND (j.job_key LIKE 'team_of_month:%' OR j.job_key LIKE 'gpsl_sport:%'
       OR j.job_key ILIKE '%interest%' OR j.job_key ILIKE '%month_lock%')
GROUP BY lower(j.gpsl_month)

UNION ALL
SELECT 5, 'month_end_balances', b.gpsl_month, count(*)::text,
       count(*) FILTER (WHERE b.balance > 0)::text,
       count(*) FILTER (WHERE b.balance < 0)::text
FROM public.club_month_end_balances b
JOIN public.competition_seasons s ON s.id = b.season_id AND s.is_current
GROUP BY b.gpsl_month

UNION ALL
SELECT 6, 'ledger_interest',
       coalesce(l.metadata->>'gpsl_month', '?'),
       l.entry_type,
       count(*)::text,
       round(sum(l.amount), 0)::text
FROM public.competition_finance_ledger l
JOIN public.competition_seasons s ON s.id = l.season_id AND s.is_current
WHERE l.entry_type IN ('eos_balance_interest', 'eos_debt_interest')
GROUP BY coalesce(l.metadata->>'gpsl_month', '?'), l.entry_type

ORDER BY 1, 3;
