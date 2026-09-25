-- =============================================================================
-- Fix stadium max capacity / expansion headroom for newly added clubs
--
-- Cause: Clubs.base_capacity DEFAULT 0. admin_club_create set Capacity but not
-- base_capacity, so new clubs kept base_capacity = 0. Then:
--   stadium_max_capacity(0) → 25000
--   headroom → max(25000 − Capacity, 0)  (wrong)
--
-- coalesce(base_capacity, Capacity) does NOT help when base_capacity is 0.
--
-- Safe re-run.
-- =============================================================================

-- 1) Repair: treat base_capacity 0 as "never set"
UPDATE public."Clubs" c
SET base_capacity = coalesce(c."Capacity", 0)::int
WHERE coalesce(c.base_capacity, 0) = 0
  AND coalesce(c."Capacity", 0) > 0;

-- 2) Create club: always seed base_capacity = Capacity
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
  v_has_continent boolean := false;
  v_has_base boolean := false;
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

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'Clubs'
      AND column_name = 'continent'
  )
  INTO v_has_continent;

  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'Clubs'
      AND column_name = 'base_capacity'
  )
  INTO v_has_base;

  IF v_has_continent AND v_has_base THEN
    EXECUTE format(
      'INSERT INTO public."Clubs" (
         "ShortName", "Club", "Stadium", "Capacity", base_capacity, "Nation", continent, is_archived
       ) VALUES ($1, $2, $3, $4, $4, $5, $6, false)'
    )
    USING
      v_short,
      v_name,
      coalesce(v_stadium, v_name || ' Stadium'),
      v_cap,
      coalesce(v_nation, 'Unknown'),
      v_continent;
  ELSIF v_has_continent THEN
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
  ELSIF v_has_base THEN
    INSERT INTO public."Clubs" (
      "ShortName", "Club", "Stadium", "Capacity", base_capacity, "Nation", is_archived
    )
    VALUES (
      v_short,
      v_name,
      coalesce(v_stadium, v_name || ' Stadium'),
      v_cap,
      v_cap,
      coalesce(v_nation, 'Unknown'),
      false
    );
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
    'capacity', v_cap,
    'base_capacity', v_cap,
    'continent', v_continent,
    'hint', 'Add badge/stadium/kit images under images/ keyed by ShortName, then assign an owner or leave vacant for auction.'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_club_create(text, text, text, integer, text, text) TO authenticated;

-- 3) Harden headroom helper: treat base_capacity 0 as unset
CREATE OR REPLACE FUNCTION public.stadium_expansion_headroom(
  p_club_short_name text
)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_base int;
  v_current int;
  v_max int;
  v_reserved int := 0;
BEGIN
  SELECT
    coalesce(nullif(c.base_capacity, 0), c."Capacity", 0)::int,
    coalesce(c."Capacity", 0)::int
  INTO v_base, v_current
  FROM public."Clubs" c
  WHERE c."ShortName" = p_club_short_name;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  v_max := public.stadium_max_capacity(v_base);

  SELECT coalesce(sum(greatest(o.seats_ordered - o.seats_delivered, 0)), 0)::int
  INTO v_reserved
  FROM public.stadium_expansion_orders o
  WHERE o.club_short_name = p_club_short_name
    AND o.status IN ('pre_build', 'awaiting_goahead', 'building');

  RETURN greatest(v_max - v_current - v_reserved, 0);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.stadium_expansion_headroom(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Sanity check after apply:
-- SELECT "ShortName", "Capacity", base_capacity,
--        public.stadium_max_capacity(coalesce(nullif(base_capacity,0), "Capacity", 0)) AS max_cap,
--        public.stadium_expansion_headroom("ShortName") AS headroom
-- FROM public."Clubs"
-- ORDER BY "ShortName";
