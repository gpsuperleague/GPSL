-- =============================================================================
-- My Club → Friendlies: opponent difficulty (1 easiest … 5 hardest)
--
-- Difficulty = average of:
--   • Ranking FDR — gpfl_fdr_for_club (owner rolling-4 ranking + club prestige)
--   • Bookies FDR — opponent's rank by bookies_club_strength among this
--     season's league clubs, same bands as the GPFL FDR (rank scaled to 40)
-- If bookies strength isn't installed, ranking FDR only.
-- Read-only RPC for the logged-in club's opponents this season. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_friendlies_opponent_difficulty()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(nullif(btrim(coalesce(public.my_club_shortname(), '')), ''));
  v_season_id bigint;
  v_has_bookies boolean := to_regprocedure('public.bookies_club_strength(text,bigint)') IS NOT NULL;
  v_has_fdr boolean := to_regprocedure('public.gpfl_fdr_for_club(text)') IS NOT NULL;
  v_out jsonb := '{}'::jsonb;
  v_map jsonb := '{}'::jsonb;
  v_pool int := 0;
  r record;
  v_rank_fdr int;
  v_book_fdr int;
  v_book_rank int;
  v_strength numeric;
  v_fdr int;
BEGIN
  IF v_club IS NULL THEN
    RETURN '{}'::jsonb;
  END IF;

  v_season_id := public.gpsl_friendlies_live_season_id();
  IF v_season_id IS NULL THEN
    SELECT id INTO v_season_id
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  -- Bookies strength for every league club this season (computed once)
  IF v_has_bookies AND v_season_id IS NOT NULL THEN
    SELECT coalesce(jsonb_object_agg(x.club, x.strength), '{}'::jsonb)
    INTO v_map
    FROM (
      SELECT DISTINCT ON (upper(ccs.club_short_name))
             upper(ccs.club_short_name) AS club,
             public.bookies_club_strength(ccs.club_short_name, v_season_id) AS strength
      FROM public.competition_club_seasons ccs
      WHERE ccs.season_id = v_season_id
        AND lower(ccs.division) IN ('superleague', 'championship_a', 'championship_b')
    ) x;
    SELECT count(*)::int INTO v_pool FROM jsonb_object_keys(v_map);
  END IF;

  FOR r IN
    SELECT DISTINCT upper(CASE WHEN upper(f.club_left) = v_club THEN f.club_right ELSE f.club_left END) AS opp
    FROM public.gpsl_friendlies f
    WHERE f.season_id = v_season_id
      AND (upper(f.club_left) = v_club OR upper(f.club_right) = v_club)
    UNION
    SELECT DISTINCT upper(CASE WHEN upper(x.club_left) = v_club THEN x.club_right ELSE x.club_left END)
    FROM public.gpsl_friendly_reports x
    WHERE x.season_id = v_season_id
      AND x.status = 'pending'
      AND (upper(x.club_left) = v_club OR upper(x.club_right) = v_club)
  LOOP
    v_rank_fdr := NULL;
    v_book_fdr := NULL;
    v_book_rank := NULL;
    v_strength := NULL;

    IF v_has_fdr THEN
      SELECT public.gpfl_fdr_for_club(c."ShortName") INTO v_rank_fdr
      FROM public."Clubs" c
      WHERE upper(c."ShortName") = r.opp
      LIMIT 1;
    END IF;

    IF v_pool > 0 AND v_map ? r.opp THEN
      v_strength := (v_map->>r.opp)::numeric;
      SELECT count(*)::int + 1 INTO v_book_rank
      FROM jsonb_each_text(v_map) e
      WHERE e.value::numeric > v_strength;

      -- Same bands as gpfl_fdr_from_strength_rank, rank scaled to a 40-club pool
      v_book_fdr := CASE
        WHEN round(v_book_rank::numeric * 40 / greatest(v_pool, 1)) <= 4 THEN 5
        WHEN round(v_book_rank::numeric * 40 / greatest(v_pool, 1)) <= 8 THEN 4
        WHEN round(v_book_rank::numeric * 40 / greatest(v_pool, 1)) <= 14 THEN 3
        WHEN round(v_book_rank::numeric * 40 / greatest(v_pool, 1)) <= 22 THEN 2
        ELSE 1
      END;
    END IF;

    v_fdr := CASE
      WHEN v_rank_fdr IS NOT NULL AND v_book_fdr IS NOT NULL
        THEN round((v_rank_fdr + v_book_fdr) / 2.0)::int
      ELSE coalesce(v_rank_fdr, v_book_fdr)
    END;

    v_out := v_out || jsonb_build_object(
      r.opp,
      jsonb_build_object(
        'fdr', v_fdr,
        'ranking_fdr', v_rank_fdr,
        'bookies_fdr', v_book_fdr,
        'bookies_rank', v_book_rank,
        'bookies_pool', nullif(v_pool, 0),
        'bookies_strength', v_strength
      )
    );
  END LOOP;

  RETURN v_out;
END;
$function$;

REVOKE ALL ON FUNCTION public.club_friendlies_opponent_difficulty() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.club_friendlies_opponent_difficulty() TO authenticated;

NOTIFY pgrst, 'reload schema';
