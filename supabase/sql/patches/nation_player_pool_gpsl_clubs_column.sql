-- =============================================================================
-- Nation player pool report: add gpsl_clubs_count (all Clubs for that nation)
-- =============================================================================
-- Total GPSL clubs with Clubs.Nation matching the international nation —
-- owned or unowned. Powers the "GPSL Clubs" column on nation_player_pool.html
-- (between Healthy clubs and Owned clubs).
-- =============================================================================

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
  gpsl_clubs_count integer,
  pool jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_empty jsonb := public.international_player_pool_empty_json();
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sign in required';
  END IF;

  RETURN QUERY
  WITH club_nation_counts AS (
    SELECT
      m.nation_code,
      count(*)::integer AS gpsl_clubs_count,
      count(*) FILTER (WHERE c.owner_id IS NOT NULL)::integer AS owned_clubs_count
    FROM public."Clubs" c
    INNER JOIN public.international_gpdb_label_map m
      ON m.norm_label = public.international_normalize_nation_label(c."Nation")
    GROUP BY m.nation_code
  )
  SELECT
    n.code,
    n.name,
    n.seed_rank,
    ion.club_short_name,
    coalesce(nullif(btrim(c.owner), ''), c."ShortName"),
    (ion.id IS NOT NULL),
    coalesce(cc.owned_clubs_count, 0),
    coalesce(cc.gpsl_clubs_count, 0),
    coalesce(cache.pool, v_empty)
  FROM public.international_nations n
  LEFT JOIN public.international_nation_player_pool_cache cache
    ON cache.nation_code = n.code
  LEFT JOIN public.international_owner_nations ion
    ON ion.nation_code = n.code AND ion.is_active = true
  LEFT JOIN public."Clubs" c ON c."ShortName" = ion.club_short_name
  LEFT JOIN club_nation_counts cc ON cc.nation_code = n.code
  WHERE n.active = true
  ORDER BY n.seed_rank;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.international_nation_player_pool_report() TO authenticated;

NOTIFY pgrst, 'reload schema';
