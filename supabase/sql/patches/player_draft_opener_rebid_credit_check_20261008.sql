-- =============================================================================
-- CHECK (read-only): opening clubs charged a join credit for rebidding
-- =============================================================================
-- Bug: the Scouting inline Bid and GPDB offer only treated earlier *join* bids
-- as "already in", so the club that OPENED a thread was charged 1 credit the
-- first time it rebid after being outbid. (Full bid page and auto/max bids
-- were correct.) Lists every wrongly charged rebid in the current draft.
-- =============================================================================

WITH b AS (SELECT * FROM public.draft_auction_window_bounds()),
bad AS (
  SELECT
    r.bid_id,
    r.bidder_club_id,
    coalesce(r.player_id, r.direct_bid_id::text) AS pid,
    r.bid_time,
    r.bid_amount
  FROM public."Player_Transfer_Bids" r
  CROSS JOIN b
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
)
SELECT
  bad.bidder_club_id AS club,
  p."Name" AS player,
  to_char(bad.bid_time AT TIME ZONE 'Europe/London', 'DD Mon HH24:MI') AS rebid_at_uk,
  bad.bid_amount,
  count(*) OVER () AS wrong_charges_total,
  (SELECT count(DISTINCT x.bidder_club_id) FROM bad x) AS clubs_affected
FROM bad
LEFT JOIN public."Players" p ON p."Konami_ID"::text = bad.pid
ORDER BY bad.bidder_club_id, bad.bid_time;
