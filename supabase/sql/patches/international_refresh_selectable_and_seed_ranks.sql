-- =============================================================================
-- International: refresh selectable nations from GPDB pool + recompute seed ranks
--
-- Sync button → international_refresh_selectable_nations()
--   1) Import missing GPDB nationalities
--   2) Refresh nation player pool cache
--   3) active = true only when pool can form a 23-man squad AND support a club
--      (same rules as international_nation_pool_is_selectable)
--   4) Nations with an active owner assignment stay active (don't hide mid-season)
--
-- Seed button → international_recompute_seed_ranks_from_pool()
--   Ranks active nations by weighted rating-band totals from the pool cache
--   (same bands as nation_player_pool). Owner draft order is unchanged.
--
-- Run in Supabase SQL Editor after international_nation_player_pool.sql
-- and international_sync_gpdb_nations.sql (or _fix).
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

CREATE OR REPLACE FUNCTION public.international_refresh_selectable_nations()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_sync jsonb := '{}'::jsonb;
  v_cache jsonb := '{}'::jsonb;
  v_activated integer := 0;
  v_deactivated integer := 0;
  v_kept_assigned integer := 0;
  v_selectable integer := 0;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  -- 1) Import any GPDB nationality labels not yet in international_nations
  IF to_regprocedure('public.international_sync_gpdb_nations()') IS NOT NULL THEN
    v_sync := public.international_sync_gpdb_nations();
  ELSE
    RAISE EXCEPTION
      'international_sync_gpdb_nations() missing — run international_sync_gpdb_nations.sql first';
  END IF;

  -- 2) Rebuild pool cache (sync may already have refreshed; do it again so
  --    newly inserted nations are included)
  IF to_regprocedure('public.international_refresh_nation_player_pool_cache()') IS NOT NULL THEN
    v_cache := public.international_refresh_nation_player_pool_cache();
  ELSE
    RAISE EXCEPTION
      'international_refresh_nation_player_pool_cache() missing — run international_nation_player_pool.sql first';
  END IF;

  IF to_regprocedure('public.international_nation_pool_is_selectable(text)') IS NULL THEN
    RAISE EXCEPTION
      'international_nation_pool_is_selectable(text) missing — run international_nation_player_pool.sql first';
  END IF;

  -- 3) Activate / deactivate from pool viability
  WITH decisions AS (
    SELECT
      n.code,
      n.active AS was_active,
      public.international_nation_pool_is_selectable(n.code) AS pool_ok,
      EXISTS (
        SELECT 1
        FROM public.international_owner_nations ion
        WHERE ion.nation_code = n.code
          AND ion.is_active = true
      ) AS has_owner
    FROM public.international_nations n
  ),
  applied AS (
    UPDATE public.international_nations n
    SET active = (d.pool_ok OR d.has_owner)
    FROM decisions d
    WHERE n.code = d.code
    RETURNING
      n.code,
      n.active AS is_active,
      d.was_active,
      d.pool_ok,
      d.has_owner
  )
  SELECT
    count(*) FILTER (WHERE is_active AND NOT was_active)::integer,
    count(*) FILTER (WHERE NOT is_active AND was_active)::integer,
    count(*) FILTER (WHERE is_active AND has_owner AND NOT pool_ok)::integer,
    count(*) FILTER (WHERE is_active)::integer
  INTO v_activated, v_deactivated, v_kept_assigned, v_selectable
  FROM applied;

  RETURN jsonb_build_object(
    'sync', v_sync,
    'cache', v_cache,
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
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF to_regprocedure('public.international_refresh_nation_player_pool_cache()') IS NOT NULL THEN
    v_cache := public.international_refresh_nation_player_pool_cache();
  END IF;

  -- Active (selectable) nations: seed_rank 1 = strongest pool
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

  -- Inactive nations: pack after active ranks (stable, out of pot draws)
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
GRANT EXECUTE ON FUNCTION public.international_refresh_selectable_nations() TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_recompute_seed_ranks_from_pool() TO authenticated;

NOTIFY pgrst, 'reload schema';
