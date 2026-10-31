SELECT id, created_at, entry_type, amount, left(description, 100) AS description,
       metadata->>'kind' AS kind, metadata->>'source' AS source
FROM public.competition_finance_ledger
WHERE upper(club_short_name) = 'MAR'
  AND coalesce(metadata->>'source','') = 'handpick_mid_season_takeover'
ORDER BY created_at DESC
LIMIT 5;
