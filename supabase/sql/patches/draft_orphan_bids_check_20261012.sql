-- =============================================================================
-- READ-ONLY: draft bids with no auction (listing_id NULL) — who else is hit?
-- matjaz (CRV) led 6 players on Sat 10 Oct, but his bids have listing_id NULL
-- and no draft listing exists for those players, so settlement never saw them.
--
-- Result grid: one row per player with free-agent draft bids since Thu 8 Oct
-- 19:00 UK where the top bid is not attached to any listing, or the listing is
-- gone. Shows leader, amount, whether signed, and every listing ever made for
-- that player (any date) so we can see if one existed and was removed.
-- =============================================================================

WITH win AS (
  SELECT (timestamp '2026-10-08 19:00' AT TIME ZONE 'Europe/London') AS s
),
draft_bids AS (
  SELECT b.*,
         coalesce(b.player_id::text, b.direct_bid_id::text) AS pid,
         ((b.bid_time AT TIME ZONE 'Europe/London') - interval '19 hours')::date AS draft_day
  FROM public."Player_Transfer_Bids" b, win
  WHERE b.is_direct = true
    AND b.seller_club_id IS NULL
    AND b.bid_time >= win.s
),
per_player_day AS (
  SELECT DISTINCT ON (d.pid, d.draft_day)
    d.pid, d.draft_day, d.bidder_club_id AS leader, d.bid_amount AS top_bid,
    d.bid_time AS top_bid_time, d.listing_id AS top_listing_id,
    d.is_first_draft_bid, d.is_draft_join, d.status
  FROM draft_bids d
  ORDER BY d.pid, d.draft_day, d.bid_amount DESC, d.bid_time ASC
),
day_stats AS (
  SELECT pid, draft_day,
         count(*) AS bids,
         count(*) FILTER (WHERE listing_id IS NULL) AS bids_no_listing,
         count(DISTINCT bidder_club_id) AS clubs
  FROM draft_bids
  GROUP BY 1, 2
)
SELECT
  to_char(p.draft_day, 'Dy DD Mon') AS draft_day,
  pl."Name" AS player,
  p.pid AS player_id,
  p.leader,
  p.top_bid,
  to_char(p.top_bid_time AT TIME ZONE 'Europe/London', 'Dy HH24:MI:SS') AS top_bid_uk,
  s.bids, s.bids_no_listing, s.clubs,
  p.top_listing_id,
  (p.top_listing_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public."Player_Transfer_Listings" x WHERE x.id = p.top_listing_id))
    AS listing_row_missing,
  pl."Contracted_Team" AS club_now,
  (SELECT string_agg(format('#%s %s %s %s→%s lead=%s won=%s', l.id, l.listing_type, l.status,
                            to_char(l.created_at AT TIME ZONE 'Europe/London', 'DyDD HH24:MI'),
                            to_char(l.end_time AT TIME ZONE 'Europe/London', 'DyDD HH24:MI'),
                            coalesce(l.current_highest_bidder, '-'), coalesce(l.winning_club, '-')),
                     ' | ' ORDER BY l.id)
   FROM public."Player_Transfer_Listings" l
   WHERE btrim(l.player_id::text) = p.pid) AS all_listings_ever,
  (SELECT max(l.id) FROM public."Player_Transfer_Listings" l
   WHERE l.listing_type = 'draft'
     AND l.created_at <= p.top_bid_time) AS max_draft_listing_id_at_bid
FROM per_player_day p
JOIN day_stats s ON s.pid = p.pid AND s.draft_day = p.draft_day
LEFT JOIN public."Players" pl ON pl."Konami_ID"::text = p.pid
WHERE s.bids_no_listing > 0
   OR (p.top_listing_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public."Player_Transfer_Listings" x WHERE x.id = p.top_listing_id))
ORDER BY p.draft_day, p.leader, pl."Name";
