-- Add owner_tag to international_nations_public (national team "Managed by" line)
-- Safe re-run after competition_international.sql

DROP VIEW IF EXISTS public.international_nations_public;
CREATE VIEW public.international_nations_public
WITH (security_invoker = false)
AS
SELECT
  n.code,
  n.name,
  n.flag_emoji,
  n.seed_rank,
  ion.club_short_name AS owner_club,
  c."Club" AS owner_club_name,
  coalesce(nullif(btrim(c.owner), ''), c."ShortName") AS owner_tag,
  (ion.id IS NOT NULL) AS is_taken
FROM public.international_nations n
LEFT JOIN public.international_owner_nations ion
  ON ion.nation_code = n.code AND ion.is_active = true
LEFT JOIN public."Clubs" c ON c."ShortName" = ion.club_short_name
WHERE n.active = true
ORDER BY n.seed_rank;

GRANT SELECT ON public.international_nations_public TO authenticated;

NOTIFY pgrst, 'reload schema';
