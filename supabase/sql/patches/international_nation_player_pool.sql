-- =============================================================================
-- International nation GPDB player pool report (admin)
-- Run after competition_international.sql + international_callup_gpdb.sql
-- After international_sync_gpdb_nations.sql
-- Powers nation_player_pool.html — pool counts by rating band, U21, position
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.international_gpdb_label_map (
  norm_label text PRIMARY KEY,
  nation_code text NOT NULL
);

CREATE INDEX IF NOT EXISTS international_gpdb_label_map_code_idx
  ON public.international_gpdb_label_map (nation_code);

CREATE INDEX IF NOT EXISTS players_nation_norm_idx
  ON public."Players" (public.international_normalize_nation_label("Nation"));

CREATE OR REPLACE FUNCTION public.international_refresh_gpdb_label_map()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count integer := 0;
BEGIN
  TRUNCATE public.international_gpdb_label_map;

  INSERT INTO public.international_gpdb_label_map (norm_label, nation_code)
  SELECT DISTINCT ON (src.norm_label)
    src.norm_label,
    src.code
  FROM (
    SELECT
      public.international_normalize_nation_label(n.name) AS norm_label,
      n.code,
      1 AS pri
    FROM public.international_nations n
    WHERE n.active = true
    UNION ALL
    SELECT upper(n.code), n.code, 2
    FROM public.international_nations n
    WHERE n.active = true
    UNION ALL
    SELECT
      public.international_normalize_nation_label(a),
      c.code,
      3
    FROM public.international_nation_catalog c
    CROSS JOIN unnest(c.aliases) AS a
    INNER JOIN public.international_nations n ON n.code = c.code AND n.active = true
  ) src
  WHERE src.norm_label IS NOT NULL AND src.norm_label <> ''
  ORDER BY src.norm_label, src.pri;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_gpdb_label_map_rows()
RETURNS TABLE (norm_label text, nation_code text)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT m.norm_label, m.nation_code
  FROM public.international_gpdb_label_map m;
$$;

CREATE OR REPLACE FUNCTION public.international_resolve_gpdb_nation_code(p_label text)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT m.nation_code
  FROM public.international_gpdb_label_map m
  WHERE m.norm_label = public.international_normalize_nation_label(p_label)
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.international_gpdb_matches_nation(
  p_gpdb_label text,
  p_nation_code text
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT public.international_resolve_gpdb_nation_code(p_gpdb_label)
    = upper(btrim(p_nation_code));
$$;

CREATE OR REPLACE FUNCTION public.international_player_matches_nation(
  p_player_id text,
  p_nation_code text
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public."Players" p
    WHERE p."Konami_ID"::text = btrim(p_player_id)
      AND public.international_resolve_gpdb_nation_code(p."Nation")
        = upper(btrim(p_nation_code))
  );
$$;

CREATE OR REPLACE FUNCTION public.international_player_pool_position_group(p_position text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE upper(btrim(coalesce(p_position, '')))
    WHEN 'GK' THEN 'gk'
    WHEN 'LB' THEN 'def'
    WHEN 'CB' THEN 'def'
    WHEN 'RB' THEN 'def'
    WHEN 'LWB' THEN 'def'
    WHEN 'RWB' THEN 'def'
    WHEN 'DMF' THEN 'mid'
    WHEN 'LMF' THEN 'mid'
    WHEN 'CMF' THEN 'mid'
    WHEN 'RMF' THEN 'mid'
    WHEN 'AMF' THEN 'mid'
    WHEN 'LW' THEN 'fwd'
    WHEN 'LWF' THEN 'fwd'
    WHEN 'SS' THEN 'fwd'
    WHEN 'RW' THEN 'fwd'
    WHEN 'RWF' THEN 'fwd'
    WHEN 'CF' THEN 'fwd'
    WHEN 'WG' THEN 'fwd'
    ELSE NULL
  END;
$$;

CREATE OR REPLACE FUNCTION public.international_player_pool_rating_band(p_rating text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  WITH r AS (
    SELECT nullif(
      regexp_replace(coalesce(btrim(p_rating), ''), '[^0-9.]', '', 'g'),
      ''
    )::numeric AS v
  )
  SELECT CASE
    WHEN (SELECT v FROM r) IS NULL THEN NULL
    WHEN (SELECT v FROM r) <= 65 THEN 'le_65'
    WHEN (SELECT v FROM r) <= 69 THEN 'r66_69'
    WHEN (SELECT v FROM r) <= 72 THEN 'r70_72'
    WHEN (SELECT v FROM r) <= 75 THEN 'r73_75'
    WHEN (SELECT v FROM r) <= 78 THEN 'r76_78'
    ELSE 'r79_plus'
  END;
$$;

CREATE OR REPLACE FUNCTION public.international_player_pool_section_json(
  p_total bigint,
  p_gk bigint,
  p_def bigint,
  p_mid bigint,
  p_fwd bigint
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT jsonb_build_object(
    'total', coalesce(p_total, 0),
    'gk', coalesce(p_gk, 0),
    'def', coalesce(p_def, 0),
    'mid', coalesce(p_mid, 0),
    'fwd', coalesce(p_fwd, 0)
  );
$$;

DROP FUNCTION IF EXISTS public.international_nation_player_pool_report();

CREATE OR REPLACE FUNCTION public.international_nation_player_pool_report()
RETURNS TABLE (
  nation_code text,
  nation_name text,
  seed_rank smallint,
  owner_club text,
  owner_tag text,
  is_taken boolean,
  owned_clubs_count integer,
  pool jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sign in required';
  END IF;

  PERFORM public.international_refresh_gpdb_label_map();

  RETURN QUERY
  WITH player_rows AS (
    SELECT
      m.nation_code,
      public.international_player_pool_position_group(p."Position") AS pos_group,
      public.international_player_pool_rating_band(p."Rating"::text) AS rating_band,
      (
        p."Age" IS NOT NULL
        AND btrim(p."Age"::text) <> ''
        AND btrim(p."Age"::text)::numeric <= 21
      ) AS is_u21
    FROM public."Players" p
    INNER JOIN public.international_gpdb_label_map m
      ON m.norm_label = public.international_normalize_nation_label(p."Nation")
    WHERE btrim(coalesce(p."Nation", '')) <> ''
  ),
  agg AS (
    SELECT
      pr.nation_code,
      count(*)::bigint AS all_total,
      count(*) FILTER (WHERE pr.pos_group = 'gk')::bigint AS all_gk,
      count(*) FILTER (WHERE pr.pos_group = 'def')::bigint AS all_def,
      count(*) FILTER (WHERE pr.pos_group = 'mid')::bigint AS all_mid,
      count(*) FILTER (WHERE pr.pos_group = 'fwd')::bigint AS all_fwd,
      count(*) FILTER (WHERE pr.rating_band = 'le_65')::bigint AS le_65_total,
      count(*) FILTER (WHERE pr.rating_band = 'le_65' AND pr.pos_group = 'gk')::bigint AS le_65_gk,
      count(*) FILTER (WHERE pr.rating_band = 'le_65' AND pr.pos_group = 'def')::bigint AS le_65_def,
      count(*) FILTER (WHERE pr.rating_band = 'le_65' AND pr.pos_group = 'mid')::bigint AS le_65_mid,
      count(*) FILTER (WHERE pr.rating_band = 'le_65' AND pr.pos_group = 'fwd')::bigint AS le_65_fwd,
      count(*) FILTER (WHERE pr.rating_band = 'r66_69')::bigint AS r66_69_total,
      count(*) FILTER (WHERE pr.rating_band = 'r66_69' AND pr.pos_group = 'gk')::bigint AS r66_69_gk,
      count(*) FILTER (WHERE pr.rating_band = 'r66_69' AND pr.pos_group = 'def')::bigint AS r66_69_def,
      count(*) FILTER (WHERE pr.rating_band = 'r66_69' AND pr.pos_group = 'mid')::bigint AS r66_69_mid,
      count(*) FILTER (WHERE pr.rating_band = 'r66_69' AND pr.pos_group = 'fwd')::bigint AS r66_69_fwd,
      count(*) FILTER (WHERE pr.rating_band = 'r70_72')::bigint AS r70_72_total,
      count(*) FILTER (WHERE pr.rating_band = 'r70_72' AND pr.pos_group = 'gk')::bigint AS r70_72_gk,
      count(*) FILTER (WHERE pr.rating_band = 'r70_72' AND pr.pos_group = 'def')::bigint AS r70_72_def,
      count(*) FILTER (WHERE pr.rating_band = 'r70_72' AND pr.pos_group = 'mid')::bigint AS r70_72_mid,
      count(*) FILTER (WHERE pr.rating_band = 'r70_72' AND pr.pos_group = 'fwd')::bigint AS r70_72_fwd,
      count(*) FILTER (WHERE pr.rating_band = 'r73_75')::bigint AS r73_75_total,
      count(*) FILTER (WHERE pr.rating_band = 'r73_75' AND pr.pos_group = 'gk')::bigint AS r73_75_gk,
      count(*) FILTER (WHERE pr.rating_band = 'r73_75' AND pr.pos_group = 'def')::bigint AS r73_75_def,
      count(*) FILTER (WHERE pr.rating_band = 'r73_75' AND pr.pos_group = 'mid')::bigint AS r73_75_mid,
      count(*) FILTER (WHERE pr.rating_band = 'r73_75' AND pr.pos_group = 'fwd')::bigint AS r73_75_fwd,
      count(*) FILTER (WHERE pr.rating_band = 'r76_78')::bigint AS r76_78_total,
      count(*) FILTER (WHERE pr.rating_band = 'r76_78' AND pr.pos_group = 'gk')::bigint AS r76_78_gk,
      count(*) FILTER (WHERE pr.rating_band = 'r76_78' AND pr.pos_group = 'def')::bigint AS r76_78_def,
      count(*) FILTER (WHERE pr.rating_band = 'r76_78' AND pr.pos_group = 'mid')::bigint AS r76_78_mid,
      count(*) FILTER (WHERE pr.rating_band = 'r76_78' AND pr.pos_group = 'fwd')::bigint AS r76_78_fwd,
      count(*) FILTER (WHERE pr.rating_band = 'r79_plus')::bigint AS r79_plus_total,
      count(*) FILTER (WHERE pr.rating_band = 'r79_plus' AND pr.pos_group = 'gk')::bigint AS r79_plus_gk,
      count(*) FILTER (WHERE pr.rating_band = 'r79_plus' AND pr.pos_group = 'def')::bigint AS r79_plus_def,
      count(*) FILTER (WHERE pr.rating_band = 'r79_plus' AND pr.pos_group = 'mid')::bigint AS r79_plus_mid,
      count(*) FILTER (WHERE pr.rating_band = 'r79_plus' AND pr.pos_group = 'fwd')::bigint AS r79_plus_fwd,
      count(*) FILTER (WHERE pr.is_u21)::bigint AS u21_total,
      count(*) FILTER (WHERE pr.is_u21 AND pr.pos_group = 'gk')::bigint AS u21_gk,
      count(*) FILTER (WHERE pr.is_u21 AND pr.pos_group = 'def')::bigint AS u21_def,
      count(*) FILTER (WHERE pr.is_u21 AND pr.pos_group = 'mid')::bigint AS u21_mid,
      count(*) FILTER (WHERE pr.is_u21 AND pr.pos_group = 'fwd')::bigint AS u21_fwd
    FROM player_rows pr
    GROUP BY pr.nation_code
  ),
  owned_clubs AS (
    SELECT
      m.nation_code,
      count(*)::integer AS owned_clubs_count
    FROM public."Clubs" c
    INNER JOIN public.international_gpdb_label_map m
      ON m.norm_label = public.international_normalize_nation_label(c."Nation")
    WHERE c.owner_id IS NOT NULL
    GROUP BY m.nation_code
  )
  SELECT
    n.code,
    n.name,
    n.seed_rank,
    ion.club_short_name,
    coalesce(nullif(btrim(c.owner), ''), c."ShortName"),
    (ion.id IS NOT NULL),
    coalesce(oc.owned_clubs_count, 0),
    jsonb_build_object(
      'all', public.international_player_pool_section_json(a.all_total, a.all_gk, a.all_def, a.all_mid, a.all_fwd),
      'le_65', public.international_player_pool_section_json(a.le_65_total, a.le_65_gk, a.le_65_def, a.le_65_mid, a.le_65_fwd),
      'r66_69', public.international_player_pool_section_json(a.r66_69_total, a.r66_69_gk, a.r66_69_def, a.r66_69_mid, a.r66_69_fwd),
      'r70_72', public.international_player_pool_section_json(a.r70_72_total, a.r70_72_gk, a.r70_72_def, a.r70_72_mid, a.r70_72_fwd),
      'r73_75', public.international_player_pool_section_json(a.r73_75_total, a.r73_75_gk, a.r73_75_def, a.r73_75_mid, a.r73_75_fwd),
      'r76_78', public.international_player_pool_section_json(a.r76_78_total, a.r76_78_gk, a.r76_78_def, a.r76_78_mid, a.r76_78_fwd),
      'r79_plus', public.international_player_pool_section_json(a.r79_plus_total, a.r79_plus_gk, a.r79_plus_def, a.r79_plus_mid, a.r79_plus_fwd),
      'u21', public.international_player_pool_section_json(a.u21_total, a.u21_gk, a.u21_def, a.u21_mid, a.u21_fwd)
    )
  FROM public.international_nations n
  LEFT JOIN agg a ON a.nation_code = n.code
  LEFT JOIN public.international_owner_nations ion
    ON ion.nation_code = n.code AND ion.is_active = true
  LEFT JOIN public."Clubs" c ON c."ShortName" = ion.club_short_name
  LEFT JOIN owned_clubs oc ON oc.nation_code = n.code
  WHERE n.active = true
  ORDER BY n.seed_rank;
END;
$function$;

SELECT public.international_refresh_gpdb_label_map();

GRANT SELECT ON public.international_gpdb_label_map TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_refresh_gpdb_label_map() TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_gpdb_label_map_rows() TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_resolve_gpdb_nation_code(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_gpdb_matches_nation(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_player_matches_nation(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_nation_player_pool_report() TO authenticated;

NOTIFY pgrst, 'reload schema';
