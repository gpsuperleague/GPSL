-- =============================================================================
-- Add Eastern Europe continent (weather / Clubs.continent / Add Club dropdown)
-- Safe re-run.
-- =============================================================================

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT
      n.nspname AS nsp,
      cl.relname AS rel,
      c.conname AS conname
    FROM pg_constraint c
    JOIN pg_class cl ON cl.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = cl.relnamespace
    JOIN pg_attribute a
      ON a.attrelid = c.conrelid
     AND a.attnum = ANY (c.conkey)
     AND NOT a.attisdropped
    WHERE c.contype = 'c'
      AND a.attname = 'continent'
      AND n.nspname = 'public'
      AND cl.relname IN ('Clubs', 'competition_continental_condition_config')
  LOOP
    EXECUTE format(
      'ALTER TABLE %I.%I DROP CONSTRAINT %I',
      r.nsp, r.rel, r.conname
    );
  END LOOP;
END $$;

ALTER TABLE public."Clubs" DROP CONSTRAINT IF EXISTS "Clubs_continent_check";
ALTER TABLE public."Clubs" DROP CONSTRAINT IF EXISTS clubs_continent_check;
ALTER TABLE public."Clubs"
  ADD CONSTRAINT clubs_continent_check CHECK (
    continent IS NULL OR continent IN (
      'south_america', 'north_america',
      'northern_europe', 'western_europe', 'southern_europe', 'eastern_europe',
      'asia', 'africa'
    )
  );

ALTER TABLE public.competition_continental_condition_config
  DROP CONSTRAINT IF EXISTS competition_continental_condition_config_continent_check;
ALTER TABLE public.competition_continental_condition_config
  DROP CONSTRAINT IF EXISTS "competition_continental_condition_config_continent_check";
ALTER TABLE public.competition_continental_condition_config
  ADD CONSTRAINT competition_continental_condition_config_continent_check CHECK (
    continent IN (
      'south_america', 'north_america',
      'northern_europe', 'western_europe', 'southern_europe', 'eastern_europe',
      'asia', 'africa'
    )
  );

-- Seed eastern_europe weather/pitch (continental: colder winters than west)
INSERT INTO public.competition_continental_condition_config (
  continent, meteorological_season,
  weather_fine_pct, weather_rain_pct, weather_snow_pct,
  pitch_normal_pct, pitch_dry_pct, pitch_wet_pct
) VALUES
  ('eastern_europe', 'spring', 45, 45, 10, 45, 25, 30),
  ('eastern_europe', 'summer', 55, 40, 5, 40, 35, 25),
  ('eastern_europe', 'autumn', 40, 50, 10, 40, 20, 40),
  ('eastern_europe', 'winter', 25, 40, 35, 35, 15, 50)
ON CONFLICT (continent, meteorological_season) DO NOTHING;

-- Nation → continent: move Central/Eastern nations into eastern_europe
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
    'sweden', 'norway', 'finland', 'denmark', 'scotland',
    'iceland', 'estonia', 'latvia', 'lithuania'
  ]) THEN
    RETURN 'northern_europe';
  END IF;

  IF v = ANY (ARRAY[
    'poland', 'czech republic', 'czechia', 'slovakia', 'hungary',
    'romania', 'bulgaria', 'serbia', 'ukraine', 'belarus', 'russia',
    'moldova', 'albania', 'north macedonia', 'macedonia',
    'montenegro', 'kosovo', 'bosnia', 'bosnia and herzegovina'
  ]) OR v LIKE '%russia%' THEN
    RETURN 'eastern_europe';
  END IF;

  IF v = ANY (ARRAY[
    'spain', 'italy', 'portugal', 'greece', 'croatia',
    'cyprus', 'malta', 'israel', 'slovenia'
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
    'luxembourg'
  ]) THEN
    RETURN 'western_europe';
  END IF;

  RETURN 'western_europe';
END;
$function$;

-- Validate continents on create (rejects legacy "europe" / "oceania")
CREATE OR REPLACE FUNCTION public.admin_club_create(
  p_short_name text,
  p_club_name text,
  p_stadium text DEFAULT NULL,
  p_capacity integer DEFAULT 30000,
  p_nation text DEFAULT NULL,
  p_continent text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_short text := upper(btrim(p_short_name));
  v_name text := btrim(p_club_name);
  v_stadium text := nullif(btrim(coalesce(p_stadium, '')), '');
  v_nation text := nullif(btrim(coalesce(p_nation, '')), '');
  v_continent text := nullif(lower(btrim(coalesce(p_continent, ''))), '');
  v_cap int := coalesce(p_capacity, 30000);
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_short IS NULL OR v_short = '' OR v_short = 'FOREIGN' THEN
    RAISE EXCEPTION 'ShortName is required (cannot be FOREIGN)';
  END IF;

  IF v_short !~ '^[A-Z0-9]{2,12}$' THEN
    RAISE EXCEPTION 'ShortName must be 2–12 letters/digits (A–Z, 0–9)';
  END IF;

  IF v_name IS NULL OR v_name = '' THEN
    RAISE EXCEPTION 'Club name is required';
  END IF;

  IF v_cap < 1000 OR v_cap > 200000 THEN
    RAISE EXCEPTION 'Capacity must be between 1,000 and 200,000';
  END IF;

  IF v_continent IS NOT NULL AND v_continent NOT IN (
    'south_america', 'north_america',
    'northern_europe', 'western_europe', 'southern_europe', 'eastern_europe',
    'asia', 'africa'
  ) THEN
    RAISE EXCEPTION
      'Continent must be northern/western/southern/eastern Europe, South/North America, Asia, or Africa';
  END IF;

  IF EXISTS (SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_short) THEN
    RAISE EXCEPTION 'Club ShortName % already exists', v_short;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE lower(btrim(c."Club")) = lower(v_name)
  ) THEN
    RAISE EXCEPTION 'Club name % already exists', v_name;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'Clubs'
      AND column_name = 'continent'
  ) THEN
    EXECUTE format(
      'INSERT INTO public."Clubs" (
         "ShortName", "Club", "Stadium", "Capacity", "Nation", continent, is_archived
       ) VALUES ($1, $2, $3, $4, $5, $6, false)'
    )
    USING
      v_short,
      v_name,
      coalesce(v_stadium, v_name || ' Stadium'),
      v_cap,
      coalesce(v_nation, 'Unknown'),
      v_continent;
  ELSE
    INSERT INTO public."Clubs" (
      "ShortName", "Club", "Stadium", "Capacity", "Nation", is_archived
    )
    VALUES (
      v_short,
      v_name,
      coalesce(v_stadium, v_name || ' Stadium'),
      v_cap,
      coalesce(v_nation, 'Unknown'),
      false
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'short_name', v_short,
    'club_name', v_name,
    'continent', v_continent,
    'hint', 'Add badge/stadium/kit images under images/ keyed by ShortName, then assign an owner or leave vacant for auction.'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_club_create(text, text, text, integer, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
