-- =============================================================================
-- Fix: excluded nations must mark their GPDB players Unavailable
--
-- Bundle now expands excluded nations into player_ids via the GPDB label map /
-- resolve helper (same path as nation pool / call-up matching).
--
-- Run once in Supabase SQL Editor, then hard-refresh GPDB.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpdb_season_excluded_player_ids(p_season_id bigint DEFAULT NULL)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ids text[];
BEGIN
  WITH open_excl_players AS (
    SELECT ep.player_id
    FROM public.gpdb_season_excluded_players ep
    JOIN public.competition_seasons s ON s.id = ep.season_id
    WHERE CASE
      WHEN p_season_id IS NOT NULL THEN ep.season_id = p_season_id
      ELSE s.is_current = true
        OR s.status IN ('active', 'preseason', 'summer_break', 'setup')
    END
  ),
  open_excl_nations AS (
    SELECT en.nation_code
    FROM public.gpdb_season_excluded_nations en
    JOIN public.competition_seasons s ON s.id = en.season_id
    WHERE CASE
      WHEN p_season_id IS NOT NULL THEN en.season_id = p_season_id
      ELSE s.is_current = true
        OR s.status IN ('active', 'preseason', 'summer_break', 'setup')
    END
  ),
  nation_players AS (
    SELECT p."Konami_ID"::text AS player_id
    FROM public."Players" p
    WHERE EXISTS (SELECT 1 FROM open_excl_nations)
      AND nullif(btrim(p."Nation"), '') IS NOT NULL
      AND (
        -- Primary: label map (same as pool cache)
        (
          to_regclass('public.international_gpdb_label_map') IS NOT NULL
          AND EXISTS (
            SELECT 1
            FROM public.international_gpdb_label_map m
            JOIN open_excl_nations xn ON xn.nation_code = m.nation_code
            WHERE m.norm_label = public.international_normalize_nation_label(p."Nation")
          )
        )
        -- Resolve helper
        OR (
          to_regprocedure('public.international_resolve_gpdb_nation_code(text)') IS NOT NULL
          AND public.international_resolve_gpdb_nation_code(p."Nation") IN (
            SELECT nation_code FROM open_excl_nations
          )
        )
        -- Plain name / code fallback
        OR EXISTS (
          SELECT 1
          FROM open_excl_nations xn
          JOIN public.international_nations n ON n.code = xn.nation_code
          WHERE upper(btrim(p."Nation")) = xn.nation_code
             OR lower(btrim(p."Nation")) = lower(btrim(n.name))
             OR (
               to_regprocedure('public.international_normalize_nation_label(text)') IS NOT NULL
               AND public.international_normalize_nation_label(p."Nation")
                 = public.international_normalize_nation_label(n.name)
             )
        )
      )
  )
  SELECT coalesce(array_agg(DISTINCT pid ORDER BY pid), ARRAY[]::text[])
  INTO v_ids
  FROM (
    SELECT player_id AS pid FROM open_excl_players
    UNION
    SELECT player_id AS pid FROM nation_players
  ) u;

  RETURN coalesce(v_ids, ARRAY[]::text[]);
END;
$function$;

-- Labels = excluded NATIONS only. Never use excluded players' Nation
-- (that wrongly blanketed whole countries, e.g. Greenwood → England).
CREATE OR REPLACE FUNCTION public.gpdb_season_excluded_nation_labels(p_season_id bigint DEFAULT NULL)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_labels text[];
BEGIN
  SELECT coalesce(array_agg(DISTINCT lab ORDER BY lab), ARRAY[]::text[])
  INTO v_labels
  FROM (
    SELECT n.name AS lab
    FROM public.international_nations n
    JOIN public.gpdb_season_excluded_nations en ON en.nation_code = n.code
    JOIN public.competition_seasons s ON s.id = en.season_id
    WHERE nullif(btrim(n.name), '') IS NOT NULL
      AND CASE
        WHEN p_season_id IS NOT NULL THEN en.season_id = p_season_id
        ELSE s.is_current = true
          OR s.status IN ('active', 'preseason', 'summer_break', 'setup')
      END
    UNION
    SELECT n.code
    FROM public.international_nations n
    JOIN public.gpdb_season_excluded_nations en ON en.nation_code = n.code
    JOIN public.competition_seasons s ON s.id = en.season_id
    WHERE CASE
      WHEN p_season_id IS NOT NULL THEN en.season_id = p_season_id
      ELSE s.is_current = true
        OR s.status IN ('active', 'preseason', 'summer_break', 'setup')
    END
  ) x
  WHERE lab IS NOT NULL;

  RETURN coalesce(v_labels, ARRAY[]::text[]);
EXCEPTION WHEN OTHERS THEN
  RETURN ARRAY[]::text[];
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpdb_season_exclusions_bundle(p_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season bigint;
  v_player_ids text[] := ARRAY[]::text[];
  v_nation_codes text[] := ARRAY[]::text[];
  v_nation_labels text[] := ARRAY[]::text[];
BEGIN
  BEGIN
    v_season := public.gpdb_exclusion_season_id(p_season_id);
  EXCEPTION WHEN OTHERS THEN
    v_season := NULL;
  END;

  BEGIN
    v_player_ids := public.gpdb_season_excluded_player_ids(p_season_id);
  EXCEPTION WHEN OTHERS THEN
    v_player_ids := ARRAY[]::text[];
  END;

  BEGIN
    SELECT coalesce(array_agg(DISTINCT en.nation_code ORDER BY en.nation_code), ARRAY[]::text[])
    INTO v_nation_codes
    FROM public.gpdb_season_excluded_nations en
    JOIN public.competition_seasons s ON s.id = en.season_id
    WHERE CASE
      WHEN p_season_id IS NOT NULL THEN en.season_id = p_season_id
      ELSE s.is_current = true
        OR s.status IN ('active', 'preseason', 'summer_break', 'setup')
    END;
  EXCEPTION WHEN OTHERS THEN
    v_nation_codes := ARRAY[]::text[];
  END;

  BEGIN
    v_nation_labels := public.gpdb_season_excluded_nation_labels(p_season_id);
  EXCEPTION WHEN OTHERS THEN
    v_nation_labels := ARRAY[]::text[];
  END;

  RETURN jsonb_build_object(
    'season_id', v_season,
    'player_ids', to_jsonb(coalesce(v_player_ids, ARRAY[]::text[])),
    'nation_codes', to_jsonb(coalesce(v_nation_codes, ARRAY[]::text[])),
    'nation_labels', to_jsonb(coalesce(v_nation_labels, ARRAY[]::text[])),
    'player_count', coalesce(cardinality(v_player_ids), 0)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpdb_season_exclusions_bundle()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.gpdb_season_exclusions_bundle(NULL::bigint);
$$;

GRANT EXECUTE ON FUNCTION public.gpdb_season_excluded_player_ids(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_season_excluded_nation_labels(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_season_exclusions_bundle(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gpdb_season_exclusions_bundle() TO authenticated;

NOTIFY pgrst, 'reload schema';
