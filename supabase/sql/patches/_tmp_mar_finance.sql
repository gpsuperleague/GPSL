SELECT c."ShortName", c."Club", c.handpick_intake, c.handpick_started_at, f.balance
FROM public."Clubs" c
LEFT JOIN public."Club_Finances" f ON upper(f.club_name) = c."ShortName"
WHERE c."ShortName" = 'MAR';

SELECT public.handpick_target_balance() AS handpick_target;
SELECT public.club_auction_default_starting_balance() AS auction_default;

-- Handpick rebuild ledger lines for MAR
SELECT id, created_at, amount, description, metadata
FROM public.club_ledger
WHERE upper(club_name) = 'MAR'
  AND (
    coalesce(metadata->>'source','') = 'handpick_intake_reset'
    OR description ILIKE '%handpick%'
  )
ORDER BY created_at DESC
LIMIT 10;

-- Recent MAR ledger to see balance_before
SELECT id, created_at, amount, left(description, 120) AS description,
       metadata->>'balance_before' AS bal_before,
       metadata->>'target_balance' AS target,
       metadata->>'source' AS source
FROM public.club_ledger
WHERE upper(club_name) = 'MAR'
ORDER BY created_at DESC
LIMIT 15;
