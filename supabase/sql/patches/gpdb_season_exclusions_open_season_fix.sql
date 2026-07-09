-- =============================================================================
-- Fix: season exclusions should match any open/current season
-- (admin may have saved against a different season_id than gpdb_exclusion_season_id)
-- Plus: GPDB shows excluded players greyed with "Unavailable" (frontend).
--
-- Re-run after gpdb_season_exclusions.sql. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpdb_player_is_season_excluded(
  p_player_id text,
  p_season_id bigint DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
BEGIN
  IF v_pid IS NULL OR v_pid = '' THEN
    RETURN false;
  END IF;

  IF p_season_id IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM public.gpdb_season_excluded_players ep
      WHERE ep.season_id = p_season_id
        AND ep.player_id = v_pid
    ) THEN
      RETURN true;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.gpdb_season_excluded_nations en
      WHERE en.season_id = p_season_id
        AND public.international_player_matches_nation(v_pid, en.nation_code)
    ) THEN
      RETURN true;
    END IF;

    RETURN false;
  END IF;

  -- No season passed: any current / open season exclusion counts
  IF EXISTS (
    SELECT 1
    FROM public.gpdb_season_excluded_players ep
    JOIN public.competition_seasons s ON s.id = ep.season_id
    WHERE ep.player_id = v_pid
      AND (
        s.is_current = true
        OR s.status IN ('active', 'preseason', 'summer_break', 'setup')
      )
  ) THEN
    RETURN true;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.gpdb_season_excluded_nations en
    JOIN public.competition_seasons s ON s.id = en.season_id
    WHERE (
        s.is_current = true
        OR s.status IN ('active', 'preseason', 'summer_break', 'setup')
      )
      AND public.international_player_matches_nation(v_pid, en.nation_code)
  ) THEN
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.gpdb_nation_is_season_excluded(
  p_nation_code text,
  p_season_id bigint DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_code text := upper(btrim(p_nation_code));
BEGIN
  IF v_code IS NULL OR v_code = '' THEN
    RETURN false;
  END IF;

  IF p_season_id IS NOT NULL THEN
    RETURN EXISTS (
      SELECT 1
      FROM public.gpdb_season_excluded_nations en
      WHERE en.season_id = p_season_id
        AND en.nation_code = v_code
    );
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.gpdb_season_excluded_nations en
    JOIN public.competition_seasons s ON s.id = en.season_id
    WHERE en.nation_code = v_code
      AND (
        s.is_current = true
        OR s.status IN ('active', 'preseason', 'summer_break', 'setup')
      )
  );
END;
$function$;

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

  RETURN coalesce(v_labels, ARRAY[]::text[]);
END;
$function$;

NOTIFY pgrst, 'reload schema';
