-- =============================================================================
-- Fix: inactive nations (e.g. Slovakia) never reappear on nation_player_pool
--
-- Root cause (chicken-and-egg):
--   1) international_refresh_gpdb_label_map() only mapped active nations
--   2) international_refresh_nation_player_pool_cache() only cached active nations
--   3) international_apply_selectable_from_pool_cache() sets active from the cache
--   4) nation_player_pool_report() only returns active = true
--
-- Once a nation was deactivated (thin pool / <2 GKs / early GPDB), later refreshes
-- stopped counting its Players."Nation" rows, so it could never become active again
-- even after GPDB grew to ≥26 players.
--
-- Run this whole file once in Supabase SQL Editor, then ONE statement at a time:
--   SELECT public.international_refresh_nation_player_pool_cache();
--   SELECT public.international_apply_selectable_from_pool_cache();
-- Optional:
--   SELECT public.international_recompute_seed_ranks_from_pool();
--
-- Sanity check for Slovakia after cache refresh:
--   SELECT n.code, n.name, n.active,
--          cache.pool->'all'->>'total' AS players,
--          cache.pool->'all'->>'gk' AS gk
--   FROM public.international_nations n
--   LEFT JOIN public.international_nation_player_pool_cache cache
--     ON cache.nation_code = n.code
--   WHERE n.code = 'SVK';
-- =============================================================================

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

  -- Include inactive nations so Apply selectable can re-activate them when the
  -- GPDB pool becomes viable.
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
    UNION ALL
    SELECT upper(n.code), n.code, 2
    FROM public.international_nations n
    UNION ALL
    SELECT
      public.international_normalize_nation_label(a),
      c.code,
      3
    FROM public.international_nation_catalog c
    CROSS JOIN unnest(c.aliases) AS a
    INNER JOIN public.international_nations n ON n.code = c.code
  ) src
  WHERE src.norm_label IS NOT NULL AND src.norm_label <> ''
  ORDER BY src.norm_label, src.pri;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_refresh_nation_player_pool_cache()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count integer := 0;
  v_at timestamptz := now();
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM public.international_refresh_gpdb_label_map();
  PERFORM set_config('statement_timeout', '120000', true);

  TRUNCATE public.international_nation_player_pool_cache;

  INSERT INTO public.international_nation_player_pool_cache (nation_code, pool, refreshed_at)
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
  )
  SELECT
    n.code,
    jsonb_build_object(
      'all', public.international_player_pool_section_json(
        coalesce(a.all_total, 0), coalesce(a.all_gk, 0), coalesce(a.all_def, 0), coalesce(a.all_mid, 0), coalesce(a.all_fwd, 0)
      ),
      'le_65', public.international_player_pool_section_json(
        coalesce(a.le_65_total, 0), coalesce(a.le_65_gk, 0), coalesce(a.le_65_def, 0), coalesce(a.le_65_mid, 0), coalesce(a.le_65_fwd, 0)
      ),
      'r66_69', public.international_player_pool_section_json(
        coalesce(a.r66_69_total, 0), coalesce(a.r66_69_gk, 0), coalesce(a.r66_69_def, 0), coalesce(a.r66_69_mid, 0), coalesce(a.r66_69_fwd, 0)
      ),
      'r70_72', public.international_player_pool_section_json(
        coalesce(a.r70_72_total, 0), coalesce(a.r70_72_gk, 0), coalesce(a.r70_72_def, 0), coalesce(a.r70_72_mid, 0), coalesce(a.r70_72_fwd, 0)
      ),
      'r73_75', public.international_player_pool_section_json(
        coalesce(a.r73_75_total, 0), coalesce(a.r73_75_gk, 0), coalesce(a.r73_75_def, 0), coalesce(a.r73_75_mid, 0), coalesce(a.r73_75_fwd, 0)
      ),
      'r76_78', public.international_player_pool_section_json(
        coalesce(a.r76_78_total, 0), coalesce(a.r76_78_gk, 0), coalesce(a.r76_78_def, 0), coalesce(a.r76_78_mid, 0), coalesce(a.r76_78_fwd, 0)
      ),
      'r79_plus', public.international_player_pool_section_json(
        coalesce(a.r79_plus_total, 0), coalesce(a.r79_plus_gk, 0), coalesce(a.r79_plus_def, 0), coalesce(a.r79_plus_mid, 0), coalesce(a.r79_plus_fwd, 0)
      ),
      'u21', public.international_player_pool_section_json(
        coalesce(a.u21_total, 0), coalesce(a.u21_gk, 0), coalesce(a.u21_def, 0), coalesce(a.u21_mid, 0), coalesce(a.u21_fwd, 0)
      )
    ),
    v_at
  FROM public.international_nations n
  LEFT JOIN agg a ON a.nation_code = n.code;
  -- All nations — active flag is decided later by Apply selectable.

  GET DIAGNOSTICS v_count = ROW_COUNT;

  UPDATE public.international_nation_player_pool_meta
  SET refreshed_at = v_at,
      nation_count = v_count
  WHERE id = 1;

  RETURN jsonb_build_object(
    'nations_cached', v_count,
    'refreshed_at', v_at
  );
END;
$function$;

-- Keep claim / apply bar aligned with nation_player_pool UI (≥26 + ≥2 GKs).
CREATE OR REPLACE FUNCTION public.international_nation_pool_json_is_selectable(p_pool jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    p_pool IS NOT NULL
    AND coalesce((p_pool->'all'->>'total')::integer, 0) >= 26
    AND coalesce((p_pool->'all'->>'gk')::integer, 0) >= 2;
$$;

GRANT EXECUTE ON FUNCTION public.international_refresh_gpdb_label_map() TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_refresh_nation_player_pool_cache() TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_nation_pool_json_is_selectable(jsonb) TO authenticated;
