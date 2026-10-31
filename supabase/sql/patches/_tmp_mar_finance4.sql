SELECT c."ShortName", c.handpick_intake, c.handpick_started_at, f.balance
FROM public."Clubs" c
LEFT JOIN public."Club_Finances" f ON upper(f.club_name) = c."ShortName"
WHERE c."ShortName" = 'MAR';

SELECT id, created_at, amount, left(description, 140) AS description,
       metadata->>'balance_before' AS bal_before,
       metadata->>'target_balance' AS target,
       metadata->>'delta' AS delta,
       metadata->>'source' AS source
FROM public.competition_finance_ledger
WHERE upper(club_short_name) = 'MAR'
ORDER BY created_at DESC
LIMIT 12;
