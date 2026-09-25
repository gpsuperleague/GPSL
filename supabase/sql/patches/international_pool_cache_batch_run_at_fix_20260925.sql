-- =============================================================================
-- Fix: pool cache batch stuck at 20/172 (run_at not continuing)
--
-- Cause: continuation relied on international_nation_player_pool_meta.refresh_run_at.
-- If that UPDATE hit 0 rows (missing meta row) or was lost, each call started a
-- NEW run_at and re-processed the same first N nations forever.
--
-- Fix: client (or SQL one-shot) passes a stable p_run_at for the whole refresh.
-- Also upserts the meta row so refresh_run_at always persists as a backup.
--
-- Run this whole file once in Supabase SQL Editor, then hard-refresh the pool page.
-- =============================================================================

ALTER TABLE public.international_nation_player_pool_meta
  ADD COLUMN IF NOT EXISTS refresh_run_at timestamptz;

INSERT INTO public.international_nation_player_pool_meta (id, refreshed_at, nation_count)
VALUES (1, NULL, 0)
ON CONFLICT (id) DO NOTHING;

-- Drop old 2-arg overload so PostgREST binds the new signature cleanly
DROP FUNCTION IF EXISTS public.international_refresh_nation_player_pool_cache_batch(integer, boolean);
DROP FUNCTION IF EXISTS public.international_refresh_nation_player_pool_cache_batch(integer, boolean, timestamptz);

CREATE OR REPLACE FUNCTION public.international_refresh_nation_player_pool_cache_batch(
  p_limit integer DEFAULT 20,
  p_start boolean DEFAULT false,
  p_run_at timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_limit integer := greatest(1, least(coalesce(nullif(p_limit, 0), 20), 40));
  v_run_at timestamptz;
  v_batch text[];
  v_processed integer := 0;
  v_pending integer := 0;
  v_total integer := 0;
  v_empty jsonb := public.international_player_pool_empty_json();
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '55000', true);

  SELECT count(*)::integer INTO v_total FROM public.international_nations;

  IF coalesce(p_start, false) THEN
    PERFORM public.international_refresh_gpdb_label_map();
    -- Prefer client-supplied run id so every HTTP batch shares one stamp
    v_run_at := coalesce(p_run_at, clock_timestamp());
    INSERT INTO public.international_nation_player_pool_meta (id, refreshed_at, nation_count, refresh_run_at)
    VALUES (1, NULL, 0, v_run_at)
    ON CONFLICT (id) DO UPDATE
      SET refresh_run_at = EXCLUDED.refresh_run_at;
  ELSE
    v_run_at := coalesce(
      p_run_at,
      (
        SELECT m.refresh_run_at
        FROM public.international_nation_player_pool_meta m
        WHERE m.id = 1
      )
    );
    IF v_run_at IS NULL THEN
      RAISE EXCEPTION
        'Pool cache refresh has no run_at — call again with p_start := true (and pass p_run_at)';
    END IF;
  END IF;

  SELECT array_agg(x.code ORDER BY x.code)
  INTO v_batch
  FROM (
    SELECT n.code
    FROM public.international_nations n
    LEFT JOIN public.international_nation_player_pool_cache c
      ON c.nation_code = n.code
    WHERE c.nation_code IS NULL
       OR c.refreshed_at IS DISTINCT FROM v_run_at
    ORDER BY n.code
    LIMIT v_limit
  ) x;

  IF v_batch IS NULL OR coalesce(array_length(v_batch, 1), 0) = 0 THEN
    UPDATE public.international_nation_player_pool_meta
    SET refreshed_at = v_run_at,
        nation_count = v_total,
        refresh_run_at = NULL
    WHERE id = 1;

    RETURN jsonb_build_object(
      'done', true,
      'nations_cached', v_total,
      'nations_total', v_total,
      'refreshed_at', v_run_at,
      'processed', 0,
      'pending', 0,
      'run_at', v_run_at
    );
  END IF;

  INSERT INTO public.international_nation_player_pool_cache (nation_code, pool, refreshed_at)
  WITH player_rows AS (
    SELECT
      m.nation_code,
      public.international_player_pool_position_group(p."Position") AS pos_group,
      public.international_player_pool_rating_band(p."Rating"::text) AS rating_band,
      (
        p."Age" IS NOT NULL
        AND btrim(p."Age"::text) ~ '^[0-9]+([.][0-9]+)?$'
        AND btrim(p."Age"::text)::numeric <= 21
      ) AS is_u21
    FROM public."Players" p
    INNER JOIN public.international_gpdb_label_map m
      ON m.norm_label = public.international_normalize_nation_label(p."Nation")
    WHERE m.nation_code = ANY (v_batch)
      AND btrim(coalesce(p."Nation", '')) <> ''
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
    b.code,
    CASE
      WHEN a.nation_code IS NULL THEN v_empty
      ELSE jsonb_build_object(
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
      )
    END,
    v_run_at
  FROM unnest(v_batch) AS b(code)
  LEFT JOIN agg a ON a.nation_code = b.code
  ON CONFLICT (nation_code) DO UPDATE
  SET pool = EXCLUDED.pool,
      refreshed_at = EXCLUDED.refreshed_at;

  GET DIAGNOSTICS v_processed = ROW_COUNT;

  SELECT count(*)::integer
  INTO v_pending
  FROM public.international_nations n
  LEFT JOIN public.international_nation_player_pool_cache c
    ON c.nation_code = n.code
  WHERE c.nation_code IS NULL
     OR c.refreshed_at IS DISTINCT FROM v_run_at;

  IF v_pending = 0 THEN
    UPDATE public.international_nation_player_pool_meta
    SET refreshed_at = v_run_at,
        nation_count = v_total,
        refresh_run_at = NULL
    WHERE id = 1;

    RETURN jsonb_build_object(
      'done', true,
      'nations_cached', v_total,
      'nations_total', v_total,
      'refreshed_at', v_run_at,
      'processed', v_processed,
      'pending', 0,
      'run_at', v_run_at
    );
  END IF;

  RETURN jsonb_build_object(
    'done', false,
    'nations_cached', v_total - v_pending,
    'nations_total', v_total,
    'refreshed_at', NULL,
    'processed', v_processed,
    'pending', v_pending,
    'run_at', v_run_at
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_refresh_nation_player_pool_cache()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_result jsonb;
  v_run_at timestamptz := clock_timestamp();
  i integer;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '300s', true);

  v_result := public.international_refresh_nation_player_pool_cache_batch(40, true, v_run_at);
  i := 0;
  WHILE NOT coalesce((v_result->>'done')::boolean, false) AND i < 80 LOOP
    i := i + 1;
    v_result := public.international_refresh_nation_player_pool_cache_batch(40, false, v_run_at);
  END LOOP;

  IF NOT coalesce((v_result->>'done')::boolean, false) THEN
    RAISE EXCEPTION 'Nation pool cache refresh did not finish after % batches', i + 1;
  END IF;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_refresh_nation_player_pool_cache_batch(integer, boolean, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_refresh_nation_player_pool_cache() TO authenticated;

-- Force PostgREST to pick up the new 3-arg signature
NOTIFY pgrst, 'reload schema';
