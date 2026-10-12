-- =============================================================================
-- OooO "nation has 79+ stars" check: don't trust a 0 from the cache (2026-10-12)
-- =============================================================================
-- club_nation_has_gpdb_star() returned the international pool cache's
-- r79_plus total when present, and only looked at Players when there was no
-- cache row. A stale / differently-scoped cache (0) turned OooO off for TIG
-- even though they had set one before.
-- Now: true if the cache says > 0 OR any GPDB player of that nation (signed or
-- not, legacy excluded) is rated at/above the star minimum.
-- Report: TIG's nation, cache value, live count, and the 79+ players found.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_nation_has_gpdb_star(p_club_short_name text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_nation text;
  v_code text;
  v_stars integer;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RETURN false;
  END IF;

  SELECT c."Nation"::text INTO v_nation
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  IF v_nation IS NULL OR btrim(v_nation) = '' THEN
    RETURN false;
  END IF;

  IF to_regclass('public.international_gpdb_label_map') IS NOT NULL
     AND to_regclass('public.international_nation_player_pool_cache') IS NOT NULL THEN
    SELECT m.nation_code INTO v_code
    FROM public.international_gpdb_label_map m
    WHERE m.norm_label = public.international_normalize_nation_label(v_nation)
    LIMIT 1;

    IF v_code IS NOT NULL THEN
      SELECT coalesce((cache.pool->'r79_plus'->>'total')::integer, 0)
      INTO v_stars
      FROM public.international_nation_player_pool_cache cache
      WHERE cache.nation_code = v_code;

      IF coalesce(v_stars, 0) > 0 THEN
        RETURN true;
      END IF;
    END IF;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public."Players" p
    WHERE public.international_normalize_nation_label(p."Nation")
            = public.international_normalize_nation_label(v_nation)
      AND coalesce(p.pesdb_unavailable, false) = false
      AND coalesce(public.club_squad_player_rating(p."Konami_ID"::text), 0)
            >= public.club_squad_star_min_rating()
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_nation_has_gpdb_star(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Report
WITH c AS (
  SELECT "Nation"::text AS nation FROM public."Clubs" WHERE "ShortName" = 'TIG'
),
code AS (
  SELECT m.nation_code
  FROM public.international_gpdb_label_map m, c
  WHERE m.norm_label = public.international_normalize_nation_label(c.nation)
  LIMIT 1
)
SELECT
  c.nation AS tig_nation,
  (SELECT nation_code FROM code) AS nation_code,
  (SELECT (cache.pool->'r79_plus'->>'total')::integer
     FROM public.international_nation_player_pool_cache cache
     WHERE cache.nation_code = (SELECT nation_code FROM code)) AS cache_r79_total,
  public.club_nation_has_gpdb_star('TIG') AS ooo_allowed_now,
  (SELECT string_agg(p."Name" || ' ' || p."Rating" || ' @ ' || coalesce(nullif(btrim(p."Contracted_Team"::text), ''), 'FA'), '; ')
     FROM public."Players" p
     WHERE public.international_normalize_nation_label(p."Nation") = public.international_normalize_nation_label(c.nation)
       AND coalesce(public.club_squad_player_rating(p."Konami_ID"::text), 0) >= public.club_squad_star_min_rating()
  ) AS nation_79plus_players,
  (SELECT string_agg(p."Name" || ' ' || p."Rating", '; ')
     FROM public."Players" p
     WHERE p."Contracted_Team" = 'TIG'
       AND public.club_squad_player_eligible_one_of_our_own(p."Konami_ID"::text, 'TIG')
  ) AS tig_ooo_eligible,
  (SELECT string_agg(p."Name" || ' ' || p."Rating", '; ')
     FROM public."Players" p
     WHERE p."Contracted_Team" = 'TIG'
       AND public.club_squad_player_eligible_fan_favourite(p."Konami_ID"::text, 'TIG')
  ) AS tig_ff_eligible
FROM c;
