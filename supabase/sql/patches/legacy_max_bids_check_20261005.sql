-- =============================================================================
-- READ-ONLY: legacy (test-season) max / auto bids still in the database
-- =============================================================================
-- "Legacy" = max bid last set BEFORE the current draft window started.
-- Run each SELECT and review before running legacy_max_bids_cleanup_20261005.sql
-- =============================================================================

-- 1) Manager draft: legacy max bids
SELECT
  m.club_short_name,
  m.manager_id,
  mg.name AS manager_name,
  m.max_amount,
  m.updated_at AS max_set_at,
  wb.draft_start AS current_draft_start
FROM public.manager_draft_max_bids m
CROSS JOIN public.manager_draft_auction_window_bounds() wb
LEFT JOIN public."Managers" mg ON mg.id = m.manager_id
WHERE wb.draft_start IS NULL OR m.updated_at < wb.draft_start
ORDER BY m.club_short_name, mg.name;

-- 2) Manager draft: bids placed in the CURRENT window by a club that holds a
--    legacy max bid on that manager (these are the auto-bids to tidy)
SELECT
  l.id AS listing_id,
  mg.name AS manager_name,
  b.bidder_club_id,
  b.bid_amount,
  b.bid_time,
  (l.current_highest_bidder = b.bidder_club_id AND l.current_highest_bid = b.bid_amount) AS is_current_lead
FROM public."Manager_Transfer_Bids" b
JOIN public."Manager_Transfer_Listings" l ON l.id = b.listing_id
JOIN public."Managers" mg ON mg.id = b.manager_id
CROSS JOIN public.manager_draft_auction_window_bounds() wb
JOIN public.manager_draft_max_bids m
  ON m.manager_id = b.manager_id
 AND upper(btrim(m.club_short_name)) = upper(btrim(b.bidder_club_id))
 AND m.updated_at < wb.draft_start
WHERE l.listing_type = 'draft'
  AND l.status = 'Active'
  AND b.is_direct = true
  AND b.bid_time >= wb.draft_start
ORDER BY mg.name, b.bid_time;

-- 3) Player draft: legacy max bids
SELECT
  m.club_short_name,
  m.player_id,
  p."Name" AS player_name,
  m.max_amount,
  m.updated_at AS max_set_at,
  wb.draft_start AS current_draft_start
FROM public.player_draft_max_bids m
CROSS JOIN public.draft_auction_window_bounds() wb
LEFT JOIN public."Players" p ON p."Konami_ID"::text = m.player_id
WHERE wb.draft_start IS NULL OR m.updated_at < wb.draft_start
ORDER BY m.club_short_name, p."Name";
