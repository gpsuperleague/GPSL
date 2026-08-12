-- =============================================================================
-- Healthy club / selectable: waive 79+ star if deep pool + 76–78 present
-- =============================================================================
-- Matches international.js nationHealthyClubCapacity():
--   If r79_plus = 0 AND r76_78 >= 1 AND total players > 100,
--   skip the 1×79+ requirement; other band floors unchanged.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.international_nation_pool_is_selectable(p_nation_code text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $function$
DECLARE
  v_pool jsonb;
  v_all jsonb;
  v_total integer;
  v_gk integer;
  v_cap integer;
  v_band record;
  v_avail integer;
  v_band_cap integer;
  v_stars integer;
  v_near integer;
  v_waive_star boolean;
BEGIN
  SELECT cache.pool INTO v_pool
  FROM public.international_nation_player_pool_cache cache
  WHERE cache.nation_code = upper(btrim(p_nation_code));

  IF v_pool IS NULL THEN
    RETURN false;
  END IF;

  v_all := v_pool->'all';
  v_total := coalesce((v_all->>'total')::integer, 0);
  v_gk := coalesce((v_all->>'gk')::integer, 0);

  IF v_total < 24 OR v_gk < 2 THEN
    RETURN false;
  END IF;

  v_cap := NULL;
  v_stars := coalesce((v_pool->'r79_plus'->>'total')::integer, 0);
  v_near := coalesce((v_pool->'r76_78'->>'total')::integer, 0);
  v_waive_star := (v_stars <= 0 AND v_near >= 1 AND v_total > 100);

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
    IF v_waive_star AND v_band.key = 'r79_plus' THEN
      CONTINUE;
    END IF;
    v_avail := coalesce((v_pool->v_band.key->>'total')::integer, 0);
    v_band_cap := v_avail / v_band.min_players;
    IF v_cap IS NULL OR v_band_cap < v_cap THEN
      v_cap := v_band_cap;
    END IF;
  END LOOP;

  RETURN coalesce(v_cap, 0) > 0;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_nation_pool_is_selectable(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
