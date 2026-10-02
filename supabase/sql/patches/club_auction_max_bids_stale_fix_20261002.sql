-- =============================================================================
-- Club auction: stop leftover max bids (e.g. from a test auction) auto-bidding
--
-- club_auction_max_bids is keyed by (owner, club) with no link to a listing, and
-- admin_club_auction_reset only cleared bids + listings. A max bid set during a
-- test auction therefore survived and fired in the real auction as soon as
-- anyone else bid on that club.
--
-- 1) Auto-bids only use max bids set (updated_at) on/after the listing opened.
-- 2) admin_club_auction_reset also clears club_auction_max_bids.
-- 3) Optional one-off cleanup at the bottom (run AFTER diagnosing).
--
-- Run in Supabase SQL Editor after club_auction_ceil_bid_500k.sql. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_auction_resolve_max_bids(p_club_short_name text)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_short text := upper(trim(p_club_short_name));
  v_listing public."Club_Auction_Listings"%rowtype;
  v_owner uuid;
  v_max numeric;
  v_min numeric;
  v_amount numeric;
  v_budget numeric;
  v_placed int := 0;
  v_i int := 0;
  v_result jsonb;
BEGIN
  IF public.auction_max_bid_resolving() THEN
    RETURN 0;
  END IF;
  PERFORM public.auction_max_bid_begin_resolve();

  IF NOT public.club_auction_bidding_open_now() THEN
    RETURN 0;
  END IF;

  LOOP
    v_i := v_i + 1;
    EXIT WHEN v_i > 40;

    SELECT * INTO v_listing
    FROM public."Club_Auction_Listings"
    WHERE club_short_name = v_short AND status = 'Active'
    FOR UPDATE;

    EXIT WHEN NOT FOUND;

    v_min := public.club_auction_min_next_bid(v_listing.id);

    SELECT m.owner_id, m.max_amount
    INTO v_owner, v_max
    FROM public.club_auction_max_bids m
    JOIN public.gpsl_owner_registry r ON r.owner_id = m.owner_id
    WHERE m.club_short_name = v_short
      AND m.updated_at >= v_listing.created_at
      AND m.max_amount >= v_min
      AND r.status = 'awaiting_club_auction'
      AND coalesce(r.pending_starting_balance, 0) >= v_min
      AND (v_listing.current_highest_bidder IS DISTINCT FROM m.owner_id)
      AND NOT EXISTS (
        SELECT 1 FROM public."Club_Auction_Listings" l2
        WHERE l2.status = 'Active'
          AND l2.current_highest_bidder = m.owner_id
          AND l2.club_short_name <> v_short
      )
    ORDER BY m.max_amount DESC, m.updated_at ASC
    LIMIT 1;

    EXIT WHEN v_owner IS NULL;

    v_budget := public.club_auction_owner_budget(v_owner);
    v_amount := public.ceil_bid_to_half_million(v_min);
    IF v_amount IS NULL OR v_amount > v_max OR v_amount > v_budget THEN
      EXIT;
    END IF;

    BEGIN
      v_result := public.club_auction_place_bid_internal(v_owner, v_short, v_amount, true);
    EXCEPTION WHEN OTHERS THEN
      EXIT;
    END;
    EXIT WHEN coalesce(v_result->>'skipped', '') <> '';
    v_placed := v_placed + 1;
    v_owner := NULL;
  END LOOP;

  RETURN v_placed;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_club_auction_reset()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listings int;
  v_bids int;
  v_max_bids int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT count(*)::int INTO v_bids FROM public."Club_Auction_Bids";
  SELECT count(*)::int INTO v_listings FROM public."Club_Auction_Listings";
  SELECT count(*)::int INTO v_max_bids FROM public.club_auction_max_bids;

  DELETE FROM public."Club_Auction_Bids" WHERE true;
  DELETE FROM public."Club_Auction_Listings" WHERE true;
  DELETE FROM public.club_auction_max_bids WHERE true;

  RETURN jsonb_build_object(
    'ok', true,
    'deleted_listings', v_listings,
    'deleted_bids', v_bids,
    'deleted_max_bids', v_max_bids
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_club_auction_reset() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Leftover max bids right now (set before their club's current listing opened)
SELECT
  coalesce(r.owner_tag, m.owner_id::text) AS owner,
  m.club_short_name,
  m.max_amount,
  m.updated_at AT TIME ZONE 'Europe/London' AS max_set_uk,
  l.created_at AT TIME ZONE 'Europe/London' AS listing_opened_uk
FROM public.club_auction_max_bids m
LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = m.owner_id
LEFT JOIN public."Club_Auction_Listings" l
  ON upper(l.club_short_name) = upper(m.club_short_name) AND l.status = 'Active'
WHERE l.id IS NULL OR m.updated_at < l.created_at
ORDER BY owner, m.club_short_name;

-- Optional one-off cleanup (run separately, AFTER you've finished diagnosing):
-- DELETE FROM public.club_auction_max_bids m
-- USING public."Club_Auction_Listings" l
-- WHERE upper(l.club_short_name) = upper(m.club_short_name)
--   AND l.status = 'Active'
--   AND m.updated_at < l.created_at;
