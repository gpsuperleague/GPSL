-- =============================================================================
-- Add Africa continent to weather / pitch / kit-season system
--
-- - Extends Clubs.continent + config CHECK lists
-- - Seeds africa spring/summer/autumn/winter probability rows
-- - Maps CIV / major African nations → africa
-- - Improves accent normalize (Ôô) so "Côte d'Ivoire" matches
--
-- Safe re-run. Then open Admin → Weather to tune Africa percentages.
-- Optional: SELECT public.competition_admin_reapply_fixture_conditions();
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Widen CHECK constraints to allow 'africa'
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.conname, c.conrelid::regclass AS tbl
    FROM pg_constraint c
    JOIN pg_attribute a
      ON a.attrelid = c.conrelid
     AND a.attnum = ANY (c.conkey)
    WHERE c.contype = 'c'
      AND a.attname = 'continent'
      AND c.conrelid::regclass::text IN (
        'public."Clubs"',
        'public.competition_continental_condition_config'
      )
  LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', r.tbl, r.conname);
  END LOOP;
END $$;

ALTER TABLE public."Clubs" DROP CONSTRAINT IF EXISTS clubs_continent_check;
ALTER TABLE public."Clubs"
  ADD CONSTRAINT clubs_continent_check CHECK (
    continent IS NULL OR continent IN (
      'south_america', 'north_america', 'northern_europe',
      'southern_europe', 'western_europe', 'asia', 'africa'
    )
  );

ALTER TABLE public.competition_continental_condition_config
  DROP CONSTRAINT IF EXISTS competition_continental_condition_config_continent_check;
ALTER TABLE public.competition_continental_condition_config
  ADD CONSTRAINT competition_continental_condition_config_continent_check CHECK (
    continent IN (
      'south_america', 'north_america', 'northern_europe',
      'southern_europe', 'western_europe', 'asia', 'africa'
    )
  );

-- ---------------------------------------------------------------------------
-- 2) Normalize accents (incl. ô) + nation → continent (incl. africa)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_normalize_nation_key(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT lower(
    regexp_replace(
      translate(
        btrim(coalesce(p_value, '')),
        'ÜüÖöÔôÄäÉéÈèÊêËëÍíÓóÚúÇçÀàÂâÃãÑñ',
        'UuOoOoAaEeEeEeIiOoUuCcAaAaAaNn'
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

  -- Africa (West / North / Central / South — tropical wet/dry + Maghreb)
  IF v = ANY (ARRAY[
    'cote d''ivoire', 'ivory coast', 'civ',
    'senegal', 'ghana', 'nigeria', 'cameroon', 'mali', 'guinea',
    'burkina faso', 'benin', 'togo', 'niger', 'liberia', 'sierra leone',
    'gambia', 'gabon', 'congo', 'congo dr', 'dr congo',
    'democratic republic of the congo', 'republic of the congo',
    'angola', 'zambia', 'zimbabwe', 'kenya', 'uganda', 'tanzania',
    'ethiopia', 'rwanda', 'sudan', 'south sudan',
    'morocco', 'egypt', 'tunisia', 'algeria', 'libya',
    'south africa', 'republic of south africa', 'rsa',
    'mozambique', 'madagascar', 'botswana', 'namibia', 'malawi'
  ]) OR v LIKE '%ivoire%' OR v LIKE '%ivory coast%' THEN
    RETURN 'africa';
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

-- ---------------------------------------------------------------------------
-- 3) GPSL month → meteorological season (Africa: wet / dry calendar)
--    Wet peak ~ May–Oct; dry / harmattan ~ Nov–Mar. Mapped onto the four
--    eFootball seasons for kit + admin weather cards.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.competition_gpsl_meteorological_season(
  p_continent text,
  p_gpsl_month text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE coalesce(p_continent, 'western_europe')
    WHEN 'south_america' THEN CASE p_gpsl_month
      WHEN 'august' THEN 'winter'
      WHEN 'september' THEN 'spring'
      WHEN 'october' THEN 'spring'
      WHEN 'november' THEN 'spring'
      WHEN 'december' THEN 'summer'
      WHEN 'january' THEN 'summer'
      WHEN 'february' THEN 'summer'
      WHEN 'march' THEN 'autumn'
      WHEN 'april' THEN 'autumn'
      WHEN 'may' THEN 'autumn'
      ELSE 'spring'
    END
    WHEN 'asia' THEN CASE p_gpsl_month
      WHEN 'march' THEN 'spring'
      WHEN 'april' THEN 'spring'
      WHEN 'may' THEN 'spring'
      WHEN 'august' THEN 'summer'
      WHEN 'september' THEN 'autumn'
      WHEN 'october' THEN 'autumn'
      WHEN 'november' THEN 'autumn'
      WHEN 'december' THEN 'winter'
      WHEN 'january' THEN 'winter'
      WHEN 'february' THEN 'winter'
      ELSE 'spring'
    END
    WHEN 'north_america' THEN CASE p_gpsl_month
      WHEN 'march' THEN 'spring'
      WHEN 'april' THEN 'spring'
      WHEN 'may' THEN 'spring'
      WHEN 'august' THEN 'summer'
      WHEN 'september' THEN 'autumn'
      WHEN 'october' THEN 'autumn'
      WHEN 'november' THEN 'autumn'
      WHEN 'december' THEN 'winter'
      WHEN 'january' THEN 'winter'
      WHEN 'february' THEN 'winter'
      ELSE 'spring'
    END
    WHEN 'africa' THEN CASE p_gpsl_month
      -- Wet season peak → summer; rains easing → autumn; dry → winter; rains return → spring
      WHEN 'august' THEN 'summer'
      WHEN 'september' THEN 'summer'
      WHEN 'october' THEN 'autumn'
      WHEN 'november' THEN 'autumn'
      WHEN 'december' THEN 'winter'
      WHEN 'january' THEN 'winter'
      WHEN 'february' THEN 'winter'
      WHEN 'march' THEN 'spring'
      WHEN 'april' THEN 'spring'
      WHEN 'may' THEN 'spring'
      ELSE 'spring'
    END
    ELSE CASE p_gpsl_month
      WHEN 'march' THEN 'spring'
      WHEN 'april' THEN 'spring'
      WHEN 'may' THEN 'spring'
      WHEN 'august' THEN 'summer'
      WHEN 'september' THEN 'autumn'
      WHEN 'october' THEN 'autumn'
      WHEN 'november' THEN 'winter'
      WHEN 'december' THEN 'winter'
      WHEN 'january' THEN 'winter'
      WHEN 'february' THEN 'winter'
      ELSE 'spring'
    END
  END;
$$;

-- ---------------------------------------------------------------------------
-- 4) Default Africa probability rows (hot / wet-dry; snow ≈ never)
-- ---------------------------------------------------------------------------
INSERT INTO public.competition_continental_condition_config (
  continent, meteorological_season,
  weather_fine_pct, weather_rain_pct, weather_snow_pct,
  pitch_normal_pct, pitch_dry_pct, pitch_wet_pct
)
VALUES
  ('africa', 'spring', 45, 55, 0, 40, 25, 35),
  ('africa', 'summer', 30, 70, 0, 30, 15, 55),
  ('africa', 'autumn', 50, 50, 0, 40, 30, 30),
  ('africa', 'winter', 80, 20, 0, 35, 50, 15)
ON CONFLICT (continent, meteorological_season) DO NOTHING;

-- Refresh stored continent from Nation (picks up Africa for CIV clubs)
UPDATE public."Clubs" c
SET continent = public.competition_nation_to_continent(c."Nation")
WHERE c."ShortName" IS DISTINCT FROM 'FOREIGN'
  AND (
    c.continent IS NULL
    OR c.continent = public.competition_nation_to_continent(c."Nation")
    OR public.competition_nation_to_continent(c."Nation") = 'africa'
  );

NOTIFY pgrst, 'reload schema';

-- Verify
SELECT
  c."ShortName",
  c."Club",
  c."Nation",
  c.continent,
  public.competition_nation_to_continent(c."Nation") AS expected
FROM public."Clubs" c
WHERE public.competition_nation_to_continent(c."Nation") = 'africa'
   OR c.continent = 'africa'
ORDER BY c."ShortName";
