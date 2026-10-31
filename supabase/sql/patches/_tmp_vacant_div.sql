-- What claim list returns (as function body would)
SELECT
  c."ShortName" AS short_name,
  coalesce(nullif(btrim(c."Club"), ''), c."ShortName") AS club_name,
  ccs.division,
  c.owner_id
FROM public.competition_club_seasons ccs
JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
JOIN public.competition_seasons s ON s.id = ccs.season_id AND s.is_current = true
WHERE c.owner_id IS NULL
  AND upper(c."ShortName") <> 'FOREIGN'
  AND coalesce(c.is_archived, false) = false
ORDER BY ccs.division NULLS LAST, c."Club";

-- Also: vacant clubs NOT in any current division (should NOT appear)
SELECT c."ShortName", c."Club"
FROM public."Clubs" c
WHERE c.owner_id IS NULL
  AND upper(c."ShortName") <> 'FOREIGN'
  AND coalesce(c.is_archived, false) = false
  AND NOT EXISTS (
    SELECT 1
    FROM public.competition_club_seasons ccs
    JOIN public.competition_seasons s ON s.id = ccs.season_id AND s.is_current = true
    WHERE ccs.club_short_name = c."ShortName"
  )
ORDER BY c."ShortName"
LIMIT 40;

-- Confirm live function definition mentions UNION ALL or not
SELECT pg_get_functiondef('public.waiting_list_vacant_clubs_for_claim()'::regprocedure)
  LIKE '%UNION ALL%' AS still_has_union_all;
