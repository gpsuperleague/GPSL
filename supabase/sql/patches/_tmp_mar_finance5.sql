SELECT f.balance AS mar_balance_now
FROM public."Club_Finances" f
WHERE upper(f.club_name) = 'MAR';

SELECT id, created_at, amount, left(description, 160) AS description, metadata
FROM public.competition_finance_ledger
WHERE upper(club_short_name) = 'MAR'
  AND (
    coalesce(metadata->>'source','') = 'handpick_intake_reset'
    OR description ILIKE '%handpick%'
    OR description ILIKE '%rebuild%'
    OR (amount = 650000000 OR amount = -650000000)
    OR created_at >= '2026-10-31'::timestamptz
  )
ORDER BY created_at DESC
LIMIT 20;

-- What was balance immediately before today?
SELECT id, created_at, amount, left(description, 120) AS description
FROM public.competition_finance_ledger
WHERE upper(club_short_name) = 'MAR'
  AND created_at >= '2026-10-30'::timestamptz
ORDER BY created_at DESC
LIMIT 25;
