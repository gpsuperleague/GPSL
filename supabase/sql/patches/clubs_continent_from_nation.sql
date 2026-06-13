-- =============================================================================
-- Populate Clubs.continent from Clubs.Nation (weather / pitch rolls)
-- Prerequisite: competition_continental_conditions.sql (competition_nation_to_continent)
-- After changing nation mapping, re-apply competition_continental_conditions.sql then re-run this file.
-- Safe to re-run — overwrites continent from Nation each time.
-- =============================================================================

-- 1) Preview (run alone first if you want to check before updating)
SELECT
  c."ShortName",
  c."Club",
  c."Nation",
  c.continent AS continent_before,
  public.competition_nation_to_continent(c."Nation") AS continent_from_nation
FROM public."Clubs" c
WHERE c."ShortName" IS DISTINCT FROM 'FOREIGN'
ORDER BY c."Club";

-- 2) Apply (all GPSL clubs except FOREIGN pseudo-club)
UPDATE public."Clubs" c
SET continent = public.competition_nation_to_continent(c."Nation")
WHERE c."ShortName" IS DISTINCT FROM 'FOREIGN';

-- 3) Audit — distinct Nation → continent after update
SELECT
  c."Nation",
  c.continent,
  count(*)::int AS clubs
FROM public."Clubs" c
WHERE c."ShortName" IS DISTINCT FROM 'FOREIGN'
GROUP BY c."Nation", c.continent
ORDER BY c."Nation", c.continent;

-- 4) Nations that defaulted to western_europe (review if mapping looks wrong)
SELECT
  c."ShortName",
  c."Club",
  c."Nation",
  c.continent
FROM public."Clubs" c
WHERE c."ShortName" IS DISTINCT FROM 'FOREIGN'
  AND c.continent = 'western_europe'
  AND public.competition_normalize_nation_key(c."Nation") NOT IN (
    'england', 'france', 'germany', 'netherlands', 'belgium', 'switzerland',
    'austria', 'wales', 'ireland', 'republic of ireland', 'northern ireland',
    'luxembourg', 'poland', 'czech republic', 'czechia', 'hungary', ''
  )
ORDER BY c."Nation", c."Club";
