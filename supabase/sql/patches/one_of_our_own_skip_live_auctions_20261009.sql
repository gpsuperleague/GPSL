-- =============================================================================
-- One of our Own draw — never draw a player who is in a live auction (2026-10-09)
-- =============================================================================
-- Late joiners can be drawn mid player-draft. Free agents with an Active
-- listing (draft auction, transfer list, direct) are excluded from the draw
-- and from the overview counts, so nobody loses a player they are bidding on.
-- Same bands as one_of_our_own_best_hg_fallback_20261005.sql.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.ooo_player_in_live_auction(p_player_id text)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public."Player_Transfer_Listings" l
    WHERE l.player_id::text = p_player_id
      AND l.status IN ('Active', 'Review', 'Seller Review')
  );
$$;

CREATE OR REPLACE FUNCTION public.ooo_nation_band(p_nation text)
RETURNS TABLE (band text, cnt integer, best_rating numeric)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  WITH fa AS (
    SELECT public.ooo_player_rating_num(p."Rating"::text) AS r
    FROM public."Players" p
    WHERE (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = '')
      AND public.normalize_nation_key(p."Nation") = public.normalize_nation_key(p_nation)
      AND public.normalize_nation_key(p."Nation") <> ''
      AND NOT public.ooo_player_in_live_auction(p."Konami_ID"::text)
  ),
  s AS (
    SELECT
      count(*) FILTER (WHERE r >= 79)::int AS n79,
      count(*) FILTER (WHERE r = 78)::int AS n78,
      count(*) FILTER (WHERE r IS NOT NULL)::int AS nall,
      max(r) AS top
    FROM fa
  )
  SELECT
    CASE
      WHEN s.n79 > 0 THEN '79+'
      WHEN s.n78 > 0 THEN '78'
      ELSE 'best HG'
    END,
    CASE
      WHEN s.n79 > 0 THEN s.n79
      WHEN s.n78 > 0 THEN s.n78
      ELSE s.nall
    END,
    s.top
  FROM s;
$$;

CREATE OR REPLACE FUNCTION public.competition_admin_one_of_our_own_overview()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN coalesce((
    WITH fa AS (
      SELECT
        public.normalize_nation_key(p."Nation") AS nkey,
        public.ooo_player_rating_num(p."Rating"::text) AS r,
        public.ooo_player_in_live_auction(p."Konami_ID"::text) AS in_auction
      FROM public."Players" p
      WHERE p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = ''
    ),
    by_nation AS (
      SELECT
        nkey,
        count(*) FILTER (WHERE r >= 79 AND NOT in_auction)::int AS n79,
        count(*) FILTER (WHERE r = 78 AND NOT in_auction)::int AS n78,
        count(*) FILTER (WHERE r IS NOT NULL AND NOT in_auction)::int AS nall,
        count(*) FILTER (WHERE in_auction)::int AS n_auction,
        max(r) FILTER (WHERE NOT in_auction) AS top
      FROM fa
      WHERE nkey IS NOT NULL AND nkey <> ''
      GROUP BY nkey
    ),
    clubs AS (
      SELECT c.*, public.normalize_nation_key(c."Nation") AS nkey
      FROM public."Clubs" c
      WHERE c."ShortName" <> 'FOREIGN'
    )
    SELECT jsonb_agg(
      jsonb_build_object(
        'short_name', c."ShortName",
        'club', c."Club",
        'nation', c."Nation",
        'already_drawn', (d.id IS NOT NULL),
        'drawn_player_id', d.player_id,
        'drawn_player_name', dp."Name",
        'drawn_fee', d.fee,
        'eligible_band', CASE
          WHEN coalesce(b.n79, 0) > 0 THEN '79+'
          WHEN coalesce(b.n78, 0) > 0 THEN '78'
          ELSE 'best HG'
        END,
        'eligible_count', CASE
          WHEN coalesce(b.n79, 0) > 0 THEN b.n79
          WHEN coalesce(b.n78, 0) > 0 THEN b.n78
          ELSE coalesce(b.nall, 0)
        END,
        'best_rating', b.top,
        'excluded_in_auction', coalesce(b.n_auction, 0)
      )
      ORDER BY c."Club"
    )
    FROM clubs c
    LEFT JOIN by_nation b ON b.nkey = c.nkey
    LEFT JOIN public.club_one_of_our_own_draws d ON d.club_short_name = c."ShortName"
    LEFT JOIN public."Players" dp ON dp."Konami_ID"::text = d.player_id
  ), '[]'::jsonb);
END;
$function$;

CREATE OR REPLACE FUNCTION public.competition_admin_draw_one_of_our_own(
  p_club_short_names text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_club text;
  v_nation text;
  v_nkey text;
  v_player_id text;
  v_player_name text;
  v_player_rating numeric;
  v_fee numeric;
  v_history_id bigint;
  v_results jsonb := '[]'::jsonb;
  v_drawn int := 0;
  v_band text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_club_short_names IS NULL OR array_length(p_club_short_names, 1) IS NULL THEN
    RAISE EXCEPTION 'Select at least one club';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No active competition season — start a season before drawing';
  END IF;

  DROP TABLE IF EXISTS _ooo_fa;
  CREATE TEMP TABLE _ooo_fa ON COMMIT DROP AS
  SELECT
    p."Konami_ID"::text AS pid,
    p."Name"::text AS pname,
    public.normalize_nation_key(p."Nation") AS nkey,
    public.ooo_player_rating_num(p."Rating"::text) AS r,
    public.ooo_player_age_num(p."Age"::text) AS age,
    coalesce(nullif(btrim(p.market_value::text), '')::numeric, 0) AS mv
  FROM public."Players" p
  WHERE (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = '')
    AND public.ooo_player_rating_num(p."Rating"::text) IS NOT NULL
    AND NOT public.ooo_player_in_live_auction(p."Konami_ID"::text);

  FOREACH v_club IN ARRAY p_club_short_names
  LOOP
    v_club := btrim(v_club);
    CONTINUE WHEN v_club = '';

    IF EXISTS (
      SELECT 1 FROM public.club_one_of_our_own_draws d
      WHERE d.club_short_name = v_club
    ) THEN
      v_results := v_results || jsonb_build_object('club', v_club, 'status', 'skipped_already');
      CONTINUE;
    END IF;

    SELECT c."Nation" INTO v_nation
    FROM public."Clubs" c
    WHERE c."ShortName" = v_club;

    IF NOT FOUND THEN
      v_results := v_results || jsonb_build_object('club', v_club, 'status', 'club_not_found');
      CONTINUE;
    END IF;

    v_nkey := public.normalize_nation_key(v_nation);
    v_player_id := NULL;

    SELECT CASE
      WHEN count(*) FILTER (WHERE f.r >= 79) > 0 THEN '79+'
      WHEN count(*) FILTER (WHERE f.r = 78) > 0 THEN '78'
      ELSE 'best HG'
    END
    INTO v_band
    FROM _ooo_fa f
    WHERE f.nkey = v_nkey;

    SELECT f.pid, f.pname, f.r, round(f.mv)
    INTO v_player_id, v_player_name, v_player_rating, v_fee
    FROM _ooo_fa f
    WHERE f.nkey = v_nkey
      AND v_nkey <> ''
      AND (
        CASE v_band
          WHEN '79+' THEN f.r >= 79
          WHEN '78' THEN f.r = 78
          ELSE true
        END
      )
    ORDER BY
      CASE WHEN v_band = 'best HG' THEN f.r END DESC NULLS LAST,
      CASE WHEN v_band = 'best HG' THEN f.age END ASC NULLS LAST,
      CASE WHEN v_band = 'best HG' THEN f.mv END DESC NULLS LAST,
      random()
    LIMIT 1;

    IF v_player_id IS NOT NULL THEN
      DELETE FROM _ooo_fa WHERE pid = v_player_id;
    END IF;

    IF v_player_id IS NULL THEN
      v_results := v_results || jsonb_build_object(
        'club', v_club,
        'status', 'no_eligible_player',
        'nation', v_nation,
        'eligible_band', 'none'
      );
      CONTINUE;
    END IF;

    BEGIN
      PERFORM public.player_assign_to_club(v_player_id, v_club, NULL::numeric, false);

      INSERT INTO public."Transfer_History" (
        player_id, seller_club_id, buyer_club_id, fee, agent_fee, transfer_time, listing_id
      )
      VALUES (
        v_player_id, NULL, v_club, v_fee, 0, now(), NULL
      )
      RETURNING id INTO v_history_id;

      PERFORM public.post_club_ledger(
        v_club,
        'transfer_purchase',
        -v_fee,
        'One of our Own draw: ' || coalesce(v_player_name, v_player_id),
        jsonb_build_object(
          'transfer_history_id', v_history_id,
          'player_id', v_player_id,
          'one_of_our_own', true,
          'eligible_band', v_band
        ),
        v_season_id,
        NULL,
        true,
        true
      );

      INSERT INTO public.club_one_of_our_own_draws (
        club_short_name, player_id, fee, season_id, transfer_history_id
      )
      VALUES (
        v_club, v_player_id, v_fee, v_season_id, v_history_id
      );

      v_drawn := v_drawn + 1;
      v_results := v_results || jsonb_build_object(
        'club', v_club,
        'status', 'drawn',
        'player_id', v_player_id,
        'player_name', v_player_name,
        'rating', v_player_rating,
        'fee', v_fee,
        'nation', v_nation,
        'eligible_band', v_band
      );
    EXCEPTION WHEN OTHERS THEN
      v_results := v_results || jsonb_build_object(
        'club', v_club, 'status', 'error', 'message', SQLERRM
      );
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_id', v_season_id,
    'drawn', v_drawn,
    'results', v_results
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.ooo_player_in_live_auction(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ooo_nation_band(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_one_of_our_own_overview() TO authenticated;
GRANT EXECUTE ON FUNCTION public.competition_admin_draw_one_of_our_own(text[]) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Check: Italian free agents the draw will now skip (in a live auction)
SELECT
  p."Name" AS player,
  p."Rating" AS rating,
  l.listing_type,
  l.status,
  l.current_highest_bidder AS leading_club
FROM public."Players" p
JOIN public."Player_Transfer_Listings" l
  ON l.player_id::text = p."Konami_ID"::text
 AND l.status IN ('Active', 'Review', 'Seller Review')
WHERE (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = '')
  AND public.normalize_nation_key(p."Nation") = public.normalize_nation_key('Italy')
ORDER BY public.ooo_player_rating_num(p."Rating"::text) DESC NULLS LAST;
