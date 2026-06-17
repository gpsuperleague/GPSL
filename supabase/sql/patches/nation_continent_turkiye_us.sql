-- Nation → continent fixes: Türkiye → asia, UnitedStates → north_america
-- Run in Supabase SQL editor, then re-run clubs_continent_from_nation.sql (step 2)
-- and re-roll fixtures on admin_weather.html if needed.

CREATE OR REPLACE FUNCTION public.competition_normalize_nation_key(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT lower(
    regexp_replace(
      translate(
        btrim(coalesce(p_value, '')),
        'ÜüÖöÄäÉéÍíÓóÚúÇç',
        'UuOoAaEeIiOoUuCc'
      ),
      '\s+',
      ' ',
      'g'
    )
  );
$$;

CREATE OR REPLACE FUNCTION public.competition_nation_to_continent(p_nation text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v text := public.competition_normalize_nation_key(p_nation);
BEGIN
  IF v = '' THEN
    RETURN 'western_europe';
  END IF;

  IF v = ANY (ARRAY[
    'brazil', 'argentina', 'chile', 'colombia', 'uruguay', 'paraguay', 'peru',
    'ecuador', 'bolivia', 'venezuela'
  ]) THEN
    RETURN 'south_america';
  END IF;

  IF v = ANY (ARRAY[
    'usa', 'united states', 'unitedstates', 'canada', 'mexico', 'new mexico'
  ]) THEN
    RETURN 'north_america';
  END IF;

  IF v = ANY (ARRAY[
    'sweden', 'norway', 'finland', 'denmark', 'scotland', 'russia',
    'iceland', 'estonia', 'latvia', 'lithuania', 'belarus', 'ukraine'
  ]) OR v LIKE '%russia%' THEN
    RETURN 'northern_europe';
  END IF;

  IF v = ANY (ARRAY[
    'spain', 'italy', 'portugal', 'greece', 'croatia', 'serbia', 'romania',
    'bulgaria', 'cyprus', 'malta', 'israel', 'slovenia', 'bosnia'
  ]) THEN
    RETURN 'southern_europe';
  END IF;

  IF v = ANY (ARRAY[
    'japan', 'korea', 'south korea', 'north korea', 'korea republic',
    'china', 'china pr', 'saudi arabia',
    'uae', 'united arab emirates', 'qatar', 'australia', 'thailand',
    'indonesia', 'malaysia', 'singapore', 'india', 'iran', 'ir iran', 'iraq',
    'turkey', 'turkiye', 'türkiye'
  ]) THEN
    RETURN 'asia';
  END IF;

  IF v = ANY (ARRAY[
    'england', 'france', 'germany', 'netherlands', 'belgium', 'switzerland',
    'austria', 'wales', 'ireland', 'republic of ireland', 'northern ireland',
    'luxembourg', 'poland', 'czech republic', 'czechia', 'hungary'
  ]) THEN
    RETURN 'western_europe';
  END IF;

  RETURN 'western_europe';
END;
$function$;

-- Refresh stored continent from Nation (overrides stale western_europe on BES/KAS/NMU)
UPDATE public."Clubs" c
SET continent = public.competition_nation_to_continent(c."Nation")
WHERE c."ShortName" IS DISTINCT FROM 'FOREIGN';

-- Verify the three clubs
SELECT
  c."ShortName",
  c."Club",
  c."Nation",
  c.continent,
  public.competition_nation_to_continent(c."Nation") AS expected
FROM public."Clubs" c
WHERE c."ShortName" IN ('BES', 'KAS', 'NMU');
