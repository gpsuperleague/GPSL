-- =============================================================================
-- PSG: reverse vardy_np's auto-bids that came from a leftover test max bid
-- (max ₿84m set 2026-08-09 in the test auction, fired 2026-10-02 19:03 / 19:04).
--
-- Choose ONE option for magreivas below (v_keep_73m):
--   false (default) -> restore magreivas leading at ₿72m (his 73m bid was only
--                      forced by the ghost auto-bid, so it is removed too)
--   true            -> keep magreivas leading at ₿73m
--
-- Also deletes every max bid left over from earlier auctions (the 9 rows set
-- 2026-08-09) so they no longer show in owners' bid windows.
--
-- Run once in the Supabase SQL Editor (after club_auction_max_bids_stale_fix).
-- =============================================================================

DO $$
DECLARE
  v_keep_73m boolean := false;   -- <- set true to keep magreivas at ₿73m

  v_vardy uuid;
  v_mag uuid;
  v_listing public."Club_Auction_Listings"%rowtype;
  v_deleted_vardy int;
  v_deleted_mag int := 0;
  v_top record;
BEGIN
  SELECT owner_id INTO v_vardy FROM public.gpsl_owner_registry
  WHERE lower(btrim(owner_tag)) = 'vardy_np';
  SELECT owner_id INTO v_mag FROM public.gpsl_owner_registry
  WHERE lower(btrim(owner_tag)) = 'magreivas';
  IF v_vardy IS NULL OR v_mag IS NULL THEN
    RAISE EXCEPTION 'Owner tag not found (vardy_np=%, magreivas=%)', v_vardy, v_mag;
  END IF;

  SELECT * INTO v_listing FROM public."Club_Auction_Listings"
  WHERE club_short_name = 'PSG' AND status = 'Active'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No active PSG listing';
  END IF;

  -- vardy_np's PSG bids (all were auto replies)
  DELETE FROM public."Club_Auction_Bids"
  WHERE listing_id = v_listing.id AND bidder_owner_id = v_vardy;
  GET DIAGNOSTICS v_deleted_vardy = ROW_COUNT;

  -- vardy_np's leftover PSG max bid
  DELETE FROM public.club_auction_max_bids
  WHERE owner_id = v_vardy AND club_short_name = 'PSG';

  IF NOT v_keep_73m THEN
    DELETE FROM public."Club_Auction_Bids"
    WHERE listing_id = v_listing.id
      AND bidder_owner_id = v_mag
      AND bid_amount = 73000000;
    GET DIAGNOSTICS v_deleted_mag = ROW_COUNT;
  END IF;

  -- Recompute the leader from remaining bids
  SELECT b.bidder_owner_id, b.bid_amount INTO v_top
  FROM public."Club_Auction_Bids" b
  WHERE b.listing_id = v_listing.id
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  UPDATE public."Club_Auction_Listings"
  SET current_highest_bid = v_top.bid_amount,
      current_highest_bidder = v_top.bidder_owner_id,
      updated_at = now()
  WHERE id = v_listing.id;

  RAISE NOTICE 'Removed % vardy_np bid(s), % magreivas bid(s). PSG now: % at %',
    v_deleted_vardy, v_deleted_mag, v_top.bidder_owner_id, v_top.bid_amount;
END $$;

-- Remove all max bids left over from earlier auctions (set before their
-- club's current listing opened)
DELETE FROM public.club_auction_max_bids m
USING public."Club_Auction_Listings" l
WHERE upper(l.club_short_name) = upper(m.club_short_name)
  AND l.status = 'Active'
  AND m.updated_at < l.created_at;

-- Check result
SELECT
  b.bid_time AT TIME ZONE 'Europe/London' AS bid_time_uk,
  coalesce(r.owner_tag, b.bidder_owner_id::text) AS bidder,
  b.bid_amount,
  (SELECT coalesce(r2.owner_tag, l.current_highest_bidder::text)
     FROM public."Club_Auction_Listings" l
     LEFT JOIN public.gpsl_owner_registry r2 ON r2.owner_id = l.current_highest_bidder
     WHERE l.club_short_name = 'PSG' AND l.status = 'Active') AS psg_leader_now,
  (SELECT l.current_highest_bid FROM public."Club_Auction_Listings" l
     WHERE l.club_short_name = 'PSG' AND l.status = 'Active') AS psg_high_bid_now
FROM public."Club_Auction_Bids" b
LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = b.bidder_owner_id
WHERE b.club_short_name = 'PSG'
ORDER BY b.bid_time;
