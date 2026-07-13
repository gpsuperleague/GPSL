-- =============================================================================
-- Auction exclusion search: GPDB-style filters (pos/nation/playstyle/age/rating/MV)
-- Run after auction_exclusions.sql (or alone if that already ran). Safe re-run.
-- =============================================================================

DROP FUNCTION IF EXISTS public.admin_auction_search_players_for_exclusion(text, int);
DROP FUNCTION IF EXISTS public.admin_auction_search_players_for_exclusion(text, int, text[], text[], text[], int, int, int, int, numeric, numeric);

CREATE OR REPLACE FUNCTION public.admin_auction_search_players_for_exclusion(
  p_query text DEFAULT NULL,
  p_limit int DEFAULT 40,
  p_positions text[] DEFAULT NULL,
  p_nations text[] DEFAULT NULL,
  p_playstyles text[] DEFAULT NULL,
  p_age_min int DEFAULT NULL,
  p_age_max int DEFAULT NULL,
  p_rating_min int DEFAULT NULL,
  p_rating_max int DEFAULT NULL,
  p_mv_min numeric DEFAULT NULL,
  p_mv_max numeric DEFAULT NULL
)
RETURNS TABLE (
  player_id text,
  player_name text,
  player_position text,
  nation text,
  age int,
  playstyle text,
  rating int,
  market_value numeric,
  already_excluded boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_q text := btrim(coalesce(p_query, ''));
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN QUERY
  SELECT
    p."Konami_ID"::text AS player_id,
    p."Name"::text AS player_name,
    p."Position"::text AS player_position,
    p."Nation"::text AS nation,
    p."Age"::int AS age,
    p."Playstyle"::text AS playstyle,
    p."Rating"::int AS rating,
    p.market_value::numeric AS market_value,
    EXISTS (
      SELECT 1 FROM public.auction_exclusion_players e WHERE e.player_id = p."Konami_ID"::text
    ) AS already_excluded
  FROM public."Players" p
  WHERE (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = '')
    AND (
      v_q = ''
      OR p."Konami_ID"::text ILIKE '%' || v_q || '%'
      OR p."Name" ILIKE '%' || v_q || '%'
    )
    AND (
      p_positions IS NULL OR cardinality(p_positions) = 0
      OR p."Position" = ANY (p_positions)
    )
    AND (
      p_nations IS NULL OR cardinality(p_nations) = 0
      OR p."Nation" = ANY (p_nations)
    )
    AND (
      p_playstyles IS NULL OR cardinality(p_playstyles) = 0
      OR p."Playstyle" = ANY (p_playstyles)
    )
    AND (p_age_min IS NULL OR p."Age" >= p_age_min)
    AND (p_age_max IS NULL OR p."Age" <= p_age_max)
    AND (p_rating_min IS NULL OR p."Rating" >= p_rating_min)
    AND (p_rating_max IS NULL OR p."Rating" <= p_rating_max)
    AND (p_mv_min IS NULL OR p.market_value >= p_mv_min)
    AND (p_mv_max IS NULL OR p.market_value <= p_mv_max)
  ORDER BY p."Rating" DESC NULLS LAST, p."Name"
  LIMIT greatest(1, least(coalesce(p_limit, 40), 80));
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_auction_search_players_for_exclusion(text, int, text[], text[], text[], int, int, int, int, numeric, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
