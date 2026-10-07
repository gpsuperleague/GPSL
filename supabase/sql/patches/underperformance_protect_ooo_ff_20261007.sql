-- =============================================================================
-- Underperformance transfer request: One of our Own + Fan Favourite protected
-- (2026-10-07)
-- =============================================================================
-- A player designated 'one_of_our_own' or 'fan_favourite' at the club is never
-- picked for the season-end transfer request. If protection (or perpetual
-- listings) empties the club's normal group, the request drops down to the
-- next group, so an eligible player is always listed while one exists.
--
-- Groups, highest to lowest ("top 4" is ranked across the whole squad):
--   top4        top 4 rated
--   big_slight  rated ≤76, not top 4
--   mid_bad     rated 74–78, aged 22+
--   mid_slight  rated 68–73, aged 22+
--   low         rated ≤72
--   any         any other squad player
--
-- Starting group by tier + band (then down the chain):
--   big  bad/abysmal → top4, big_slight, mid_bad, mid_slight, low, any
--   big  slight      → big_slight, top4, mid_bad, mid_slight, low, any
--   medium bad/abys. → mid_bad, mid_slight, low, any
--   medium slight    → mid_slight, mid_bad, low, any
--   low  any miss    → low, any
-- Safe to re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_player_transfer_request_protected(
  p_club_short_name text,
  p_player_id text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.club_squad_player_designations d
    WHERE d.club_short_name = p_club_short_name
      AND d.player_id = p_player_id
      AND d.designation IN ('one_of_our_own', 'fan_favourite')
  );
$$;

CREATE OR REPLACE FUNCTION public.club_underperformance_pool_chain(
  p_tier text,
  p_band text
)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_tier = 'big' AND lower(coalesce(p_band, '')) = 'slight'
      THEN ARRAY['big_slight', 'top4', 'mid_bad', 'mid_slight', 'low', 'any']
    WHEN p_tier = 'big'
      THEN ARRAY['top4', 'big_slight', 'mid_bad', 'mid_slight', 'low', 'any']
    WHEN p_tier = 'medium' AND lower(coalesce(p_band, '')) = 'slight'
      THEN ARRAY['mid_slight', 'mid_bad', 'low', 'any']
    WHEN p_tier = 'medium'
      THEN ARRAY['mid_bad', 'mid_slight', 'low', 'any']
    ELSE ARRAY['low', 'any']
  END;
$$;

CREATE OR REPLACE FUNCTION public.club_underperformance_pool_label(p_pool text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_pool
    WHEN 'top4' THEN 'One random player from the top 4 rated'
    WHEN 'big_slight' THEN 'One random player rated 76 or below (not one of the top 4)'
    WHEN 'mid_bad' THEN 'One random player rated 74–78, aged 22+'
    WHEN 'mid_slight' THEN 'One random player rated 68–73, aged 22+'
    WHEN 'low' THEN 'One random player rated 72 or below'
    ELSE 'One random squad player'
  END;
$$;

-- Eligible players in one group (protected + perpetually listed excluded)
CREATE OR REPLACE FUNCTION public.club_underperformance_pool_players(
  p_club_short_name text,
  p_pool text
)
RETURNS TABLE (o_player_id text, o_name text, o_rating numeric, o_age numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH squad AS (
    SELECT
      p."Konami_ID"::text AS pid,
      p."Name"::text AS pname,
      public.player_rating_numeric(p."Rating"::text) AS rating,
      public.player_age_numeric(p."Age"::text) AS age,
      row_number() OVER (
        ORDER BY public.player_rating_numeric(p."Rating"::text) DESC NULLS LAST, p."Konami_ID"
      ) AS rk
    FROM public."Players" p
    WHERE public.player_contracted_club_key(p."Contracted_Team") = p_club_short_name
  )
  SELECT s.pid, s.pname, s.rating, s.age
  FROM squad s
  WHERE CASE p_pool
          WHEN 'top4' THEN s.rk <= 4
          WHEN 'big_slight' THEN s.rk > 4 AND s.rating <= 76
          WHEN 'mid_bad' THEN s.rating BETWEEN 74 AND 78 AND s.age > 21
          WHEN 'mid_slight' THEN s.rating BETWEEN 68 AND 73 AND s.age > 21
          WHEN 'low' THEN s.rating <= 72
          ELSE true
        END
    AND NOT public.club_player_transfer_request_protected(p_club_short_name, s.pid)
    AND NOT EXISTS (
      SELECT 1 FROM public."Player_Transfer_Listings" l
      WHERE l.player_id = s.pid
        AND l.perpetual_renew = true
        AND l.status IN ('Active', 'Review', 'Seller Review')
    );
$$;

CREATE OR REPLACE FUNCTION public.club_underperformance_pick_player(
  p_club_short_name text,
  p_tier text,
  p_band text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_pool text;
  v_player_id text;
BEGIN
  FOREACH v_pool IN ARRAY public.club_underperformance_pool_chain(
    p_tier, coalesce(nullif(btrim(p_band), ''), 'bad')
  ) LOOP
    SELECT pp.o_player_id INTO v_player_id
    FROM public.club_underperformance_pool_players(p_club_short_name, v_pool) pp
    ORDER BY random()
    LIMIT 1;
    EXIT WHEN v_player_id IS NOT NULL;
  END LOOP;
  RETURN v_player_id;
END;
$fn$;

-- Season Review candidate list: first non-empty group in the same chain
CREATE OR REPLACE FUNCTION public.season_review_listing_pool(
  p_club_short_name text,
  p_tier text,
  p_band text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_chain text[] := public.club_underperformance_pool_chain(p_tier, coalesce(nullif(btrim(p_band), ''), 'bad'));
  v_pool text;
  v_list jsonb;
BEGIN
  FOREACH v_pool IN ARRAY v_chain LOOP
    SELECT jsonb_agg(
             jsonb_build_object('name', pp.o_name, 'rating', pp.o_rating, 'age', pp.o_age)
             ORDER BY pp.o_rating DESC NULLS LAST, pp.o_name
           )
    INTO v_list
    FROM public.club_underperformance_pool_players(p_club_short_name, v_pool) pp;

    IF v_list IS NOT NULL THEN
      RETURN jsonb_build_object(
        'rule', public.club_underperformance_pool_label(v_pool),
        'pool_code', v_pool,
        'dropped', v_pool IS DISTINCT FROM v_chain[1],
        'pool', v_list,
        'pool_count', jsonb_array_length(v_list)
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'rule', public.club_underperformance_pool_label(v_chain[1]),
    'pool_code', v_chain[1],
    'dropped', false,
    'pool', '[]'::jsonb,
    'pool_count', 0
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.season_review_listing_pool(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.club_player_transfer_request_protected(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
