-- Evening transfer list + draft stuck after 7pm (listings vanished from Transfer Market but no deals).
-- Run in Supabase SQL Editor, then: SELECT admin_transferengine_run();  (or SELECT transferengine_run();)
--
-- Transfer Market hides Active rows when end_time < now() — engine must still process them.

-- 1) Diagnose: expired but still Active (waiting for engine)
SELECT
  l.id,
  l.listing_type,
  l.status,
  l.end_time,
  l.transfer_completed,
  l.current_highest_bid,
  l.current_highest_bidder,
  l.was_extended,
  p."Name" AS player
FROM "Player_Transfer_Listings" l
LEFT JOIN "Players" p ON p."Konami_ID"::text = l.player_id::text
WHERE l.status = 'Active'
  AND l.listing_type IS DISTINCT FROM 'draft'
  AND l.end_time <= now()
ORDER BY l.end_time DESC;

-- 2) Diagnose: draft still open
SELECT
  l.id,
  l.status,
  l.current_highest_bid,
  l.current_highest_bidder,
  p."Name" AS player,
  g.draft_random_finish_time,
  g.draft_random_finish_time IS NOT NULL AND now() >= g.draft_random_finish_time AS draft_finish_due,
  public.transferengine_standard_listings_block_draft_settlement(
    now(),
    g.draft_random_finish_time
  ) AS draft_blocked_by_list
FROM "Player_Transfer_Listings" l
CROSS JOIN global_settings g
LEFT JOIN "Players" p ON p."Konami_ID"::text = l.player_id::text
WHERE g.id = 1
  AND l.listing_type = 'draft'
  AND l.status = 'Active';

-- 3) Backfill high bid columns from bid rows (if sync trigger was missing)
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
  ORDER BY listing_id, bid_amount DESC, bid_time DESC
) x
WHERE l.id = x.listing_id
  AND l.status = 'Active'
  AND (l.current_highest_bid IS NULL OR l.current_highest_bidder IS NULL);

-- 4) Process everything now (requires transferengine_sync_listing_high_bid in DB)
SELECT transferengine_run();

-- 5) After run: completed transfers tonight
SELECT
  h.transfer_time,
  p."Name" AS player,
  h.seller_club_id,
  h.buyer_club_id,
  h.fee
FROM "Transfer_History" h
LEFT JOIN "Players" p ON p."Konami_ID"::text = h.player_id::text
WHERE h.transfer_time >= now() - interval '36 hours'
ORDER BY h.transfer_time DESC;
