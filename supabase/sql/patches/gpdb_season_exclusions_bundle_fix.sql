-- =============================================================================
-- Fix: gpdb_season_exclusions_bundle 400 on GPDB
--
-- Causes:
-- 1) PostgREST needs a zero-arg overload when JS calls rpc() with no body
-- 2) Bundle passed a single resolved season_id into player_ids — missed
--    exclusions saved on another open season
--
-- Run once in Supabase SQL Editor, then hard-refresh GPDB.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpdb_season_excluded_player_ids(p_season_id bigint DEFAULT NULL)
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(array_agg(DISTINCT ep.player_id ORDER BY ep.player_id), ARRAY[]::text[])
  FROM public.gpdb_season_excluded_players ep
  JOIN public.competition_seasons s ON s.id = ep.season_id
  WHERE CASE
    WHEN p_season_id IS NOT NULL THEN ep.season_id = p_season_id
    ELSE s.is_current = true
      OR s.status IN ('active', 'preseason', 'summer_break', 'setup')
  END;
$$;

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
  BEGIN
    IF to_regclass('public.international_gpdb_label_map') IS NOT NULL THEN
      SELECT coalesce(array_agg(DISTINCT lab ORDER BY lab), ARRAY[]::text[])
      INTO v_labels
      FROM (
        SELECT m.gpdb_label AS lab
        FROM public.international_gpdb_label_map m
        JOIN public.gpdb_season_excluded_nations en ON en.nation_code = m.nation_code
        JOIN public.competition_seasons s ON s.id = en.season_id
        WHERE nullif(btrim(m.gpdb_label), '') IS NOT NULL
          AND CASE
            WHEN p_season_id IS NOT NULL THEN en.season_id = p_season_id
            ELSE s.is_current = true
              OR s.status IN ('active', 'preseason', 'summer_break', 'setup')
          END
        UNION
        SELECT n.name
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
    ELSE
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
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_labels := ARRAY[]::text[];
  END;

  RETURN coalesce(v_labels, ARRAY[]::text[]);
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
    -- Pass through p_season_id (NULL = all open seasons), not only resolved id
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
    'nation_labels', to_jsonb(coalesce(v_nation_labels, ARRAY[]::text[]))
  );
END;
$function$;

-- Zero-arg overload for PostgREST / supabase.rpc("…") with empty body
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
