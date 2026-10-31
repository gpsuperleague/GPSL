SELECT
  c."ShortName" AS short_name,
  coalesce(nullif(btrim(c."Club"), ''), c."ShortName") AS club_name,
  ccs.division
FROM public.competition_club_seasons ccs
JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
JOIN public.competition_seasons s ON s.id = ccs.season_id AND s.is_current = true
WHERE c.owner_id IS NULL
  AND upper(c."ShortName") <> 'FOREIGN'
  AND coalesce(c.is_archived, false) = false
ORDER BY ccs.division NULLS LAST, c."Club";
