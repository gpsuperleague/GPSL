SELECT c."ShortName", c.handpick_intake, c.handpick_started_at, f.balance
FROM public."Clubs" c
LEFT JOIN public."Club_Finances" f ON upper(f.club_name) = c."ShortName"
WHERE c."ShortName" = 'MAR';

SELECT public.handpick_target_balance() AS handpick_target;

SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name ILIKE '%ledger%'
ORDER BY 1;
