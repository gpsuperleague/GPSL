-- =============================================================================
-- Fix: nation claim rejected as “GPDB pool too small” despite being selectable
--
-- Cause: international_nation_pool_is_selectable() was overwritten to use
-- club-depth band floors (79+, U21 quotas, etc.). Nation pick UI and
-- Apply selectable only require a 23-man squad bar (≥24 players, ≥2 GKs).
-- Austria (and similar) could appear selectable, then fail on claim.
--
-- Club-depth bands stay informational (pool page / healthy-club capacity).
-- They must NOT gate World Cup nation selection.
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.international_nation_pool_json_is_selectable(p_pool jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    p_pool IS NOT NULL
    AND coalesce((p_pool->'all'->>'total')::integer, 0) >= 24
    AND coalesce((p_pool->'all'->>'gk')::integer, 0) >= 2;
$$;

CREATE OR REPLACE FUNCTION public.international_nation_pool_is_selectable(p_nation_code text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pool jsonb;
BEGIN
  SELECT cache.pool INTO v_pool
  FROM public.international_nation_player_pool_cache cache
  WHERE cache.nation_code = upper(btrim(p_nation_code));

  RETURN public.international_nation_pool_json_is_selectable(v_pool);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_nation_pool_json_is_selectable(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.international_nation_pool_is_selectable(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Optional check (Austria):
-- SELECT public.international_nation_pool_is_selectable('AUT');
-- Expect true when pool cache has ≥24 players and ≥2 GKs for AUT.
-- Superseded by international_squad_size_26_28_20260814.sql (≥26 / max 28).
