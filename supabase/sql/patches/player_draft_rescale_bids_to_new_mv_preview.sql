-- =============================================================================
-- PREVIEW: rescale Active player-draft bids to new market values (READ-ONLY)
-- =============================================================================
-- Shows threads that would be adjusted:
--   listing.market_value IS DISTINCT FROM Players.market_value
--   (threads already snapped to the new MV are ignored)
--
-- Per thread:
--   old_open = first draft bid (is_first_draft_bid / earliest), else listing MV
--   new_open = Players.market_value
--   ratio    = new_open / old_open
--   first bid → new_open; other bids → round(amount × ratio)
-- =============================================================================

WITH draft_listings AS (
  SELECT
    l.id AS listing_id,
    l.player_id::text AS player_id,
    nullif(btrim(l.market_value::text), '')::numeric AS listing_mv,
    l.current_highest_bid::numeric AS listing_high,
    nullif(btrim(p.market_value::text), '')::numeric AS player_mv,
    p."Name"::text AS player_name
  FROM public."Player_Transfer_Listings" l
  JOIN public."Players" p
    ON btrim(p."Konami_ID"::text) = btrim(l.player_id::text)
  WHERE l.listing_type = 'draft'
    AND l.status = 'Active'
    AND l.seller_club_id IS NULL
),
first_bids AS (
  SELECT DISTINCT ON (b.listing_id)
    b.listing_id,
    b.bid_id,
    b.bid_amount::numeric AS first_bid
  FROM public."Player_Transfer_Bids" b
  JOIN draft_listings d ON d.listing_id = b.listing_id
  ORDER BY
    b.listing_id,
    CASE WHEN coalesce(b.is_first_draft_bid, false) THEN 0 ELSE 1 END,
    b.bid_time ASC NULLS LAST,
    b.bid_id ASC
),
targets AS (
  SELECT
    d.*,
    f.bid_id AS first_bid_id,
    coalesce(f.first_bid, d.listing_mv) AS old_open,
    d.player_mv AS new_open
  FROM draft_listings d
  LEFT JOIN first_bids f ON f.listing_id = d.listing_id
  WHERE d.player_mv IS NOT NULL
    AND d.player_mv > 0
    AND d.listing_mv IS DISTINCT FROM d.player_mv
),
bid_preview AS (
  SELECT
    t.listing_id,
    t.player_id,
    t.player_name,
    t.old_open,
    t.new_open,
    round(t.new_open / t.old_open, 6) AS ratio,
    count(b.bid_id)::int AS bid_count,
    min(b.bid_amount)::numeric AS old_min_bid,
    max(b.bid_amount)::numeric AS old_max_bid,
    min(
      CASE
        WHEN b.bid_id = t.first_bid_id THEN t.new_open
        ELSE round(b.bid_amount::numeric * (t.new_open / t.old_open))
      END
    ) AS new_min_bid,
    max(
      CASE
        WHEN b.bid_id = t.first_bid_id THEN t.new_open
        ELSE round(b.bid_amount::numeric * (t.new_open / t.old_open))
      END
    ) AS new_max_bid
  FROM targets t
  LEFT JOIN public."Player_Transfer_Bids" b ON b.listing_id = t.listing_id
  WHERE t.old_open IS NOT NULL
    AND t.old_open > 0
  GROUP BY
    t.listing_id, t.player_id, t.player_name, t.old_open, t.new_open, t.first_bid_id
)
SELECT
  player_name,
  player_id,
  listing_id,
  old_open,
  new_open,
  ratio,
  bid_count,
  old_min_bid,
  old_max_bid,
  new_min_bid,
  new_max_bid,
  (new_max_bid - old_max_bid) AS high_delta
FROM bid_preview
ORDER BY abs(coalesce(new_open, 0) - coalesce(old_open, 0)) DESC, player_name
LIMIT 200;

-- Summary counts
WITH draft_listings AS (
  SELECT
    l.id AS listing_id,
    nullif(btrim(l.market_value::text), '')::numeric AS listing_mv,
    nullif(btrim(p.market_value::text), '')::numeric AS player_mv
  FROM public."Player_Transfer_Listings" l
  JOIN public."Players" p
    ON btrim(p."Konami_ID"::text) = btrim(l.player_id::text)
  WHERE l.listing_type = 'draft'
    AND l.status = 'Active'
    AND l.seller_club_id IS NULL
)
SELECT
  count(*) FILTER (WHERE listing_mv IS DISTINCT FROM player_mv) AS listings_to_rescale,
  count(*) FILTER (WHERE listing_mv IS NOT DISTINCT FROM player_mv) AS listings_already_new_mv,
  count(*) AS active_draft_listings
FROM draft_listings;
