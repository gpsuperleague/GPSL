-- Backfill current_highest_bid / current_highest_bidder on listings created from
-- accepted direct offers before the Transfer Centre fix (opening bid existed but
-- listing columns were null).
--
-- Run once in Supabase SQL Editor.

UPDATE public."Player_Transfer_Listings" l
SET
  current_highest_bid = b.bid_amount,
  current_highest_bidder = b.bidder_club_id
FROM (
  SELECT DISTINCT ON (listing_id)
    listing_id,
    bid_amount,
    bidder_club_id
  FROM public."Player_Transfer_Bids"
  WHERE listing_id IS NOT NULL
    AND COALESCE(is_opening_bid, false) = true
  ORDER BY listing_id, bid_time DESC
) b
WHERE l.id = b.listing_id
  AND (l.current_highest_bid IS NULL OR l.current_highest_bidder IS NULL);

-- Fallback: any listing with bids but no high bid → use latest bid on that listing
UPDATE public."Player_Transfer_Listings" l
SET
  current_highest_bid = x.bid_amount,
  current_highest_bidder = x.bidder_club_id
FROM (
  SELECT DISTINCT ON (listing_id)
    listing_id,
    bid_amount,
    bidder_club_id
  FROM public."Player_Transfer_Bids"
  WHERE listing_id IS NOT NULL
    AND lower(coalesce(status::text, '')) IN ('active', 'opening')
  ORDER BY listing_id, bid_amount DESC, bid_time DESC
) x
WHERE l.id = x.listing_id
  AND (l.current_highest_bid IS NULL OR l.current_highest_bidder IS NULL);

-- Direct listings with no listing bids: use accepted direct offer on same player
UPDATE public."Player_Transfer_Listings" l
SET
  current_highest_bid = b.bid_amount,
  current_highest_bidder = b.bidder_club_id
FROM public."Player_Transfer_Bids" b
WHERE l.listing_type = 'direct'
  AND l.status = 'Active'
  AND (l.current_highest_bid IS NULL OR l.current_highest_bidder IS NULL)
  AND b.is_direct = true
  AND lower(coalesce(b.status::text, '')) IN ('accepted', 'active')
  AND btrim(coalesce(b.player_id, b.direct_bid_id::text, '')) = btrim(l.player_id::text)
  AND (b.listing_id IS NULL OR b.listing_id = l.id)
  AND (l.reserve_price IS NULL OR b.bid_amount = l.reserve_price);

NOTIFY pgrst, 'reload schema';
