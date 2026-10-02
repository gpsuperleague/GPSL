-- =============================================================================
-- Admin: withdraw Jerom's bid(s) on Monaco in the club auction (one-off).
--
-- Removes ALL of the owner's bids + max bid on that club, then recomputes the
-- leader from the remaining bids (no bids left -> listing back to no bids,
-- next bid starts at the opening bid). He can then bid again on any club.
--
-- Club is matched by short name OR full club name (Clubs."Club").
-- Run once in the Supabase SQL Editor.
-- =============================================================================

DO $$
DECLARE
  v_tag  text := 'Jerom';    -- <- owner withdrawing
  v_club text := 'Monaco';   -- <- club short name or full name

  v_owner uuid;
  v_short text;
  v_listing public."Club_Auction_Listings"%rowtype;
  v_deleted int;
  v_top record;
BEGIN
  SELECT owner_id INTO v_owner FROM public.gpsl_owner_registry
  WHERE lower(btrim(owner_tag)) = lower(btrim(v_tag));
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Owner tag % not found (check gpsl_owner_registry.owner_tag)', v_tag;
  END IF;

  SELECT l.club_short_name INTO v_short
  FROM public."Club_Auction_Listings" l
  LEFT JOIN public."Clubs" c ON c."ShortName" = l.club_short_name
  WHERE l.status = 'Active'
    AND (upper(l.club_short_name) = upper(btrim(v_club))
         OR c."Club" ILIKE '%' || btrim(v_club) || '%')
  ORDER BY (upper(l.club_short_name) = upper(btrim(v_club))) DESC
  LIMIT 1;
  IF v_short IS NULL THEN
    RAISE EXCEPTION 'No active club auction listing matching %', v_club;
  END IF;

  SELECT * INTO v_listing FROM public."Club_Auction_Listings"
  WHERE club_short_name = v_short AND status = 'Active'
  FOR UPDATE;

  DELETE FROM public."Club_Auction_Bids"
  WHERE listing_id = v_listing.id AND bidder_owner_id = v_owner;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  DELETE FROM public.club_auction_max_bids
  WHERE owner_id = v_owner AND club_short_name = v_short;

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

  RAISE NOTICE 'Withdrew % bid(s) by % on % (%). New leader: % at %',
    v_deleted, v_tag, v_club, v_short,
    coalesce(v_top.bidder_owner_id::text, 'none'),
    coalesce(v_top.bid_amount::text, 'no bids');
END $$;

-- Check result
SELECT
  l.club_short_name,
  c."Club" AS club_name,
  coalesce(r.owner_tag, l.current_highest_bidder::text, '— no bids —') AS leader_now,
  l.current_highest_bid,
  public.club_auction_min_next_bid(l.id) AS next_min_bid,
  (SELECT count(*) FROM public."Club_Auction_Bids" b WHERE b.listing_id = l.id) AS bids_remaining
FROM public."Club_Auction_Listings" l
LEFT JOIN public."Clubs" c ON c."ShortName" = l.club_short_name
LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = l.current_highest_bidder
WHERE l.status = 'Active'
  AND (upper(l.club_short_name) = 'MONACO' OR c."Club" ILIKE '%monaco%');
