-- =============================================================================
-- Fix: nation_labels must NOT include nationalities of individually excluded
-- players (e.g. excluding Greenwood must not mark all England as Unavailable).
-- Labels = excluded NATIONS only (name, code, catalog aliases, label-map keys).
-- Run once in Supabase SQL Editor. Safe to re-run.
-- =============================================================================

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
  -- Core: official name + ISO code for excluded nations only
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
  ) core
  WHERE lab IS NOT NULL;

  -- Optional: catalog aliases (e.g. "State of Israel")
  IF to_regclass('public.international_nation_catalog') IS NOT NULL THEN
    SELECT coalesce(array_agg(DISTINCT lab ORDER BY lab), v_labels)
    INTO v_labels
    FROM (
      SELECT unnest(coalesce(v_labels, ARRAY[]::text[])) AS lab
      UNION
      SELECT a AS lab
      FROM public.international_nation_catalog c
      JOIN public.gpdb_season_excluded_nations en ON en.nation_code = c.code
      JOIN public.competition_seasons s ON s.id = en.season_id
      CROSS JOIN LATERAL unnest(c.aliases) AS a
      WHERE nullif(btrim(a), '') IS NOT NULL
        AND CASE
          WHEN p_season_id IS NOT NULL THEN en.season_id = p_season_id
          ELSE s.is_current = true
            OR s.status IN ('active', 'preseason', 'summer_break', 'setup')
        END
    ) z
    WHERE lab IS NOT NULL;
  END IF;

  -- Optional: label-map keys that resolve to excluded nation codes
  -- (norm_label is the lookup key; also keep display variants via catalog above)
  IF to_regclass('public.international_gpdb_label_map') IS NOT NULL THEN
    SELECT coalesce(array_agg(DISTINCT lab ORDER BY lab), v_labels)
    INTO v_labels
    FROM (
      SELECT unnest(coalesce(v_labels, ARRAY[]::text[])) AS lab
      UNION
      SELECT m.norm_label AS lab
      FROM public.international_gpdb_label_map m
      JOIN public.gpdb_season_excluded_nations en ON en.nation_code = m.nation_code
      JOIN public.competition_seasons s ON s.id = en.season_id
      WHERE nullif(btrim(m.norm_label), '') IS NOT NULL
        AND CASE
          WHEN p_season_id IS NOT NULL THEN en.season_id = p_season_id
          ELSE s.is_current = true
            OR s.status IN ('active', 'preseason', 'summer_break', 'setup')
        END
    ) z
    WHERE lab IS NOT NULL;
  END IF;

  RETURN coalesce(v_labels, ARRAY[]::text[]);
EXCEPTION WHEN OTHERS THEN
  RETURN ARRAY[]::text[];
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpdb_season_excluded_nation_labels(bigint) TO authenticated;

-- Expected with only ISR excluded: ["ISR","Israel", ...] — NOT "England"
-- SELECT public.gpdb_season_exclusions_bundle(NULL::bigint) -> 'nation_labels';

NOTIFY pgrst, 'reload schema';
