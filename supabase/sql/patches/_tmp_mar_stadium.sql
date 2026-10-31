SELECT public.club_stadium_infra_purchase_cost('MAR') AS mar_stadium_cost;
SELECT public.club_auction_default_starting_balance() AS starting_650;
SELECT balance FROM public."Club_Finances" WHERE upper(club_name)='MAR';

-- Existing stadium / infra lines for MAR this season
SELECT id, created_at, entry_type, amount, left(description, 120) AS description,
       metadata->>'kind' AS kind, metadata->>'source' AS source
FROM public.competition_finance_ledger
WHERE upper(club_short_name)='MAR'
  AND (
    entry_type ILIKE '%infra%'
    OR description ILIKE '%stadium%'
    OR description ILIKE '%takeover%'
  )
ORDER BY created_at DESC
LIMIT 15;
