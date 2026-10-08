-- =============================================================================
-- FIX: refund join credits wrongly charged to opening clubs on rebid
-- =============================================================================
-- See player_draft_opener_rebid_credit_check_20261008.sql. Re-marks those
-- rebids as plain bids (not a join, no credit used) — exactly what the full
-- bid page records for an opener raising its bid. Credits are counted live
-- from bid rows, so each affected club gets its credit back straight away.
-- Site fix: scouting_draft_actions.js + gpdb_v2.js (push with this).
-- Safe re-run.
-- =============================================================================

WITH b AS (SELECT * FROM public.draft_auction_window_bounds()),
fixed AS (
  UPDATE public."Player_Transfer_Bids" r
  SET is_draft_join = false,
      draft_join_consumed = false
  FROM b
  WHERE r.is_direct AND r.seller_club_id IS NULL
    AND r.draft_join_consumed = true
    AND r.bid_time >= b.draft_start
    AND EXISTS (
      SELECT 1 FROM public."Player_Transfer_Bids" f
      WHERE f.bidder_club_id = r.bidder_club_id
        AND coalesce(f.player_id, f.direct_bid_id::text) = coalesce(r.player_id, r.direct_bid_id::text)
        AND f.is_direct AND f.seller_club_id IS NULL
        AND f.is_first_draft_bid = true
        AND f.bid_time >= b.draft_start
        AND f.bid_time < r.bid_time
    )
  RETURNING r.bidder_club_id
)
SELECT
  count(*) AS rebids_fixed,
  count(DISTINCT bidder_club_id) AS clubs_refunded,
  string_agg(DISTINCT bidder_club_id, ', ') AS clubs
FROM fixed;
