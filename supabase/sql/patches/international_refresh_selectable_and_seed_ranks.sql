-- =============================================================================
-- International selectable nations — split steps (fit ~60s Supabase gateway)
--
-- Run this WHOLE file once in SQL Editor (DDL only — should be quick).
--
-- Then run ONE statement at a time:
--   1) SELECT public.international_sync_gpdb_nation_labels(25);
--      Re-run until inserted = 0 (imports in small batches).
--   2) SELECT public.international_refresh_nation_player_pool_cache();
--      Slowest — if it times out, use Admin → Refresh pool cache, or retry.
--   3) SELECT public.international_apply_selectable_from_pool_cache();
--   4) SELECT public.international_recompute_seed_ranks_from_pool();
--
-- If you already have nations + a fresh pool cache, skip to step 3.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.international_nation_pool_strength_score(p_pool jsonb)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    coalesce((p_pool->'r79_plus'->>'total')::numeric, 0) * 100
    + coalesce((p_pool->'r76_78'->>'total')::numeric, 0) * 40
    + coalesce((p_pool->'r73_75'->>'total')::numeric, 0) * 20
    + coalesce((p_pool->'r70_72'->>'total')::numeric, 0) * 10
    + coalesce((p_pool->'r66_69'->>'total')::numeric, 0) * 4
    + coalesce((p_pool->'le_65'->>'total')::numeric, 0) * 1
    + coalesce((p_pool->'u21'->>'total')::numeric, 0) * 2
    + coalesce((p_pool->'all'->>'total')::numeric, 0) * 0.01;
$$;

CREATE OR REPLACE FUNCTION public.international_nation_pool_json_is_selectable(p_pool jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_all jsonb;
  v_total integer;
  v_gk integer;
  v_cap integer;
  v_band record;
  v_avail integer;
  v_band_cap integer;
BEGIN
  IF p_pool IS NULL THEN
    RETURN false;
  END IF;

  v_all := p_pool->'all';
  v_total := coalesce((v_all->>'total')::integer, 0);
  v_gk := coalesce((v_all->>'gk')::integer, 0);

  IF v_total < 24 OR v_gk < 2 THEN
    RETURN false;
  END IF;

  v_cap := NULL;
  FOR v_band IN
    SELECT *
    FROM (
      VALUES
        ('r79_plus', 1),
        ('r76_78', 1),
        ('r73_75', 5),
        ('r70_72', 10),
        ('r66_69', 10),
        ('le_65', 5),
        ('u21', 8)
    ) AS bands(key, min_players)
  LOOP
    v_avail := coalesce((p_pool->v_band.key->>'total')::integer, 0);
    v_band_cap := v_avail / v_band.min_players;
    IF v_cap IS NULL OR v_band_cap < v_cap THEN
      v_cap := v_band_cap;
    END IF;
  END LOOP;

  RETURN coalesce(v_cap, 0) > 0;
END;
$function$;

-- Drop both overloads so we can redefine cleanly
DROP FUNCTION IF EXISTS public.international_sync_gpdb_nation_labels();
DROP FUNCTION IF EXISTS public.international_sync_gpdb_nation_labels(integer);

-- ---------------------------------------------------------------------------
-- Step 1: import missing labels in SMALL batches (no pool cache, no 2nd scan)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.international_sync_gpdb_nation_labels(
  p_limit integer DEFAULT 25
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_code text;
  v_emoji text;
  v_rank integer;
  v_inserted integer := 0;
  v_skipped integer := 0;
  v_limit integer := greatest(coalesce(p_limit, 25), 1);
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '55000', true);

  SELECT coalesce(max(seed_rank), 0) INTO v_rank FROM public.international_nations;

  FOR v_row IN
    WITH known AS (
      SELECT public.international_normalize_nation_label(n.name) AS norm_label
      FROM public.international_nations n
      UNION
      SELECT upper(btrim(n.code))
      FROM public.international_nations n
      UNION
      SELECT public.international_normalize_nation_label(a)
      FROM public.international_nation_catalog c
      CROSS JOIN unnest(c.aliases) AS a
      WHERE EXISTS (
        SELECT 1 FROM public.international_nations n WHERE n.code = c.code
      )
    ),
    gpdb AS (
      SELECT
        btrim(p."Nation") AS label,
        public.international_normalize_nation_label(p."Nation") AS norm_label,
        count(*)::integer AS players
      FROM public."Players" p
      WHERE btrim(coalesce(p."Nation", '')) <> ''
      GROUP BY 1, 2
    )
    SELECT g.label, g.norm_label, g.players
    FROM gpdb g
    WHERE g.norm_label IS NOT NULL
      AND g.norm_label <> ''
      AND NOT EXISTS (
        SELECT 1 FROM known k WHERE k.norm_label = g.norm_label
      )
    ORDER BY g.players DESC, g.label ASC
    LIMIT v_limit
  LOOP
    v_code := NULL;
    v_emoji := '🏳️';

    IF to_regprocedure('public.international_catalog_match_code(text)') IS NOT NULL THEN
      v_code := public.international_catalog_match_code(v_row.label);
    END IF;

    IF v_code IS NOT NULL THEN
      SELECT c.flag_emoji INTO v_emoji
      FROM public.international_nation_catalog c
      WHERE c.code = v_code;
    END IF;

    IF v_code IS NULL THEN
      v_code := public.international_generate_nation_code(v_row.label);
      v_emoji := '🏳️';
    END IF;

    IF EXISTS (SELECT 1 FROM public.international_nations n WHERE n.code = v_code) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_rank := v_rank + 1;
    INSERT INTO public.international_nations (code, name, flag_emoji, seed_rank, active)
    VALUES (v_code, v_row.label, coalesce(v_emoji, '🏳️'), v_rank, true);
    v_inserted := v_inserted + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'inserted', v_inserted,
    'skipped_existing_code', v_skipped,
    'batch_limit', v_limit,
    'nations_total', (SELECT count(*) FROM public.international_nations),
    'note', CASE
      WHEN v_inserted > 0 OR v_skipped > 0 THEN
        'Batch done — run again until inserted = 0'
      ELSE 'No missing labels left to import'
    END
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Step 3: apply active/inactive from EXISTING pool cache (fast)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.international_apply_selectable_from_pool_cache()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cache_count integer := 0;
  v_activated integer := 0;
  v_deactivated integer := 0;
  v_kept_assigned integer := 0;
  v_selectable integer := 0;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT count(*)::integer INTO v_cache_count
  FROM public.international_nation_player_pool_cache;

  IF v_cache_count = 0 THEN
    RAISE EXCEPTION
      'Nation pool cache is empty. Run SELECT public.international_refresh_nation_player_pool_cache(); first (alone), then retry this.';
  END IF;

  WITH decisions AS (
    SELECT
      n.code,
      n.active AS was_active,
      public.international_nation_pool_json_is_selectable(cache.pool) AS pool_ok,
      EXISTS (
        SELECT 1
        FROM public.international_owner_nations ion
        WHERE ion.nation_code = n.code
          AND ion.is_active = true
      ) AS has_owner
    FROM public.international_nations n
    LEFT JOIN public.international_nation_player_pool_cache cache
      ON cache.nation_code = n.code
  ),
  applied AS (
    UPDATE public.international_nations n
    SET active = (d.pool_ok OR d.has_owner)
    FROM decisions d
    WHERE n.code = d.code
    RETURNING
      n.active AS is_active,
      d.was_active,
      d.pool_ok,
      d.has_owner
  )
  SELECT
    coalesce(count(*) FILTER (WHERE is_active AND NOT was_active), 0)::integer,
    coalesce(count(*) FILTER (WHERE NOT is_active AND was_active), 0)::integer,
    coalesce(count(*) FILTER (WHERE is_active AND has_owner AND NOT pool_ok), 0)::integer,
    coalesce(count(*) FILTER (WHERE is_active), 0)::integer
  INTO v_activated, v_deactivated, v_kept_assigned, v_selectable
  FROM applied;

  RETURN jsonb_build_object(
    'cache_rows', v_cache_count,
    'activated', v_activated,
    'deactivated', v_deactivated,
    'kept_active_for_assignment', v_kept_assigned,
    'active_nations', v_selectable,
    'inactive_nations', (
      SELECT count(*)::integer
      FROM public.international_nations
      WHERE active = false
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_refresh_selectable_nations()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_result := public.international_apply_selectable_from_pool_cache();
  RETURN v_result || jsonb_build_object(
    'note',
    'Applied selectable flags from existing pool cache only. Import labels / refresh cache separately if needed.'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.international_recompute_seed_ranks_from_pool()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_cache jsonb := '{}'::jsonb;
  v_active integer := 0;
  v_inactive integer := 0;
  v_cache_count integer := 0;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT count(*)::integer INTO v_cache_count
  FROM public.international_nation_player_pool_cache;

  IF v_cache_count = 0 THEN
    RAISE EXCEPTION
      'Nation pool cache is empty. Run SELECT public.international_refresh_nation_player_pool_cache(); first.';
  END IF;

  v_cache := jsonb_build_object(
    'nations_cached', v_cache_count,
    'refreshed_via', 'existing_cache'
  );

  WITH scored AS (
    SELECT
      n.code,
      public.international_nation_pool_strength_score(cache.pool) AS strength,
      coalesce((cache.pool->'all'->>'total')::numeric, 0) AS players_total,
      n.name
    FROM public.international_nations n
    LEFT JOIN public.international_nation_player_pool_cache cache
      ON cache.nation_code = n.code
    WHERE n.active = true
  ),
  ranked AS (
    SELECT
      code,
      row_number() OVER (
        ORDER BY strength DESC, players_total DESC, name ASC, code ASC
      )::smallint AS new_rank
    FROM scored
  )
  UPDATE public.international_nations n
  SET seed_rank = r.new_rank
  FROM ranked r
  WHERE n.code = r.code;

  GET DIAGNOSTICS v_active = ROW_COUNT;

  WITH ranked_inactive AS (
    SELECT
      n.code,
      (
        coalesce(
          (SELECT max(seed_rank) FROM public.international_nations WHERE active = true),
          0
        )
        + row_number() OVER (ORDER BY n.name ASC, n.code ASC)
      )::smallint AS new_rank
    FROM public.international_nations n
    WHERE n.active = false
  )
  UPDATE public.international_nations n
  SET seed_rank = r.new_rank
  FROM ranked_inactive r
  WHERE n.code = r.code;

  GET DIAGNOSTICS v_inactive = ROW_COUNT;

  RETURN jsonb_build_object(
    'cache', v_cache,
    'active_ranked', v_active,
    'inactive_ranked', v_inactive,
    'top_nations', (
      SELECT coalesce(
        jsonb_agg(
          jsonb_build_object(
            'seed_rank', t.seed_rank,
            'code', t.code,
            'name', t.name,
            'strength', t.strength
          )
          ORDER BY t.seed_rank
        ),
        '[]'::jsonb
      )
      FROM (
        SELECT
          n.seed_rank,
          n.code,
          n.name,
          public.international_nation_pool_strength_score(cache.pool) AS strength
        FROM public.international_nations n
        LEFT JOIN public.international_nation_player_pool_cache cache
          ON cache.nation_code = n.code
        WHERE n.active = true
        ORDER BY n.seed_rank
        LIMIT 10
      ) t
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_nation_pool_strength_score(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_nation_pool_json_is_selectable(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_sync_gpdb_nation_labels(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_apply_selectable_from_pool_cache() TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_refresh_selectable_nations() TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_recompute_seed_ranks_from_pool() TO authenticated;

NOTIFY pgrst, 'reload schema';
