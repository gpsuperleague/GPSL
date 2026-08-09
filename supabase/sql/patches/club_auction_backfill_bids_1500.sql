-- =============================================================================
-- Backfill club auction bid threads after stadium cost ₿1,000 → ₿1,500 / seat
--
-- For each Active listing:
--   new_opening = capacity × 1,500
--   old_opening = capacity × 1,000
--   delta       = new_opening − old_opening  (= capacity × 500)
--
-- If any bid (or current high) is still below new_opening, shift ALL bids on
-- that listing by +delta so:
--   - first bid lands at / above the new opening floor
--   - gaps between subsequent bids stay the same (e.g. +₿500k steps)
-- Also bumps club_auction_max_bids on that club by the same delta.
--
-- Idempotent: skips listings whose bids are already ≥ new_opening.
-- Prerequisite: club_auction_stadium_value_1500.sql (opening rate = ×1500).
-- =============================================================================

DO $$
DECLARE
  r record;
  v_new_opening numeric;
  v_old_opening numeric;
  v_delta numeric;
  v_shifted_listings int := 0;
  v_shifted_bids int := 0;
  v_shifted_maxes int := 0;
  v_need boolean;
  v_new_high numeric;
  v_n int;
BEGIN
  FOR r IN
    SELECT
      l.id AS listing_id,
      l.club_short_name,
      coalesce(c."Capacity", 0)::bigint AS capacity,
      l.current_highest_bid,
      l.current_highest_bidder
    FROM public."Club_Auction_Listings" l
    JOIN public."Clubs" c ON c."ShortName" = l.club_short_name
    WHERE l.status = 'Active'
    ORDER BY l.id
  LOOP
    v_new_opening := greatest(r.capacity, 0)::numeric * 1500;
    v_old_opening := greatest(r.capacity, 0)::numeric * 1000;
    v_delta := v_new_opening - v_old_opening;

    IF v_delta <= 0 THEN
      CONTINUE;
    END IF;

    -- Keep opening / reserve on the new rate
    UPDATE public."Club_Auction_Listings"
    SET opening_bid = v_new_opening,
        reserve_price = v_new_opening,
        updated_at = now()
    WHERE id = r.listing_id
      AND (
        opening_bid IS DISTINCT FROM v_new_opening
        OR reserve_price IS DISTINCT FROM v_new_opening
      );

    SELECT EXISTS (
      SELECT 1
      FROM public."Club_Auction_Bids" b
      WHERE b.listing_id = r.listing_id
        AND b.bid_amount < v_new_opening
    )
    OR (
      r.current_highest_bid IS NOT NULL
      AND r.current_highest_bid < v_new_opening
    )
    INTO v_need;

    IF NOT v_need THEN
      CONTINUE;
    END IF;

    UPDATE public."Club_Auction_Bids" b
    SET bid_amount = b.bid_amount + v_delta
    WHERE b.listing_id = r.listing_id;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_shifted_bids := v_shifted_bids + v_n;

    SELECT max(b.bid_amount)
    INTO v_new_high
    FROM public."Club_Auction_Bids" b
    WHERE b.listing_id = r.listing_id;

    UPDATE public."Club_Auction_Listings"
    SET current_highest_bid = v_new_high,
        updated_at = now()
    WHERE id = r.listing_id
      AND v_new_high IS NOT NULL;

    -- Proxy maxes: same lift so they still sit above the raised thread
    IF to_regclass('public.club_auction_max_bids') IS NOT NULL THEN
      UPDATE public.club_auction_max_bids m
      SET max_amount = m.max_amount + v_delta,
          updated_at = now()
      WHERE m.club_short_name = r.club_short_name;

      GET DIAGNOSTICS v_n = ROW_COUNT;
      v_shifted_maxes := v_shifted_maxes + v_n;
    END IF;

    v_shifted_listings := v_shifted_listings + 1;

    RAISE NOTICE
      'Backfilled % (cap %, +₿%): high → %',
      r.club_short_name,
      r.capacity,
      to_char(v_delta, 'FM999,999,999,999'),
      to_char(coalesce(v_new_high, v_new_opening), 'FM999,999,999,999');
  END LOOP;

  RAISE NOTICE
    'Done. listings_shifted=% bids_shifted=% maxes_touched=%',
    v_shifted_listings, v_shifted_bids, v_shifted_maxes;
END $$;

NOTIFY pgrst, 'reload schema';

-- Verify: no Active bid below its listing's new opening
SELECT
  l.club_short_name,
  c."Capacity" AS capacity,
  l.opening_bid,
  l.current_highest_bid,
  min(b.bid_amount) AS lowest_bid,
  max(b.bid_amount) AS highest_bid,
  count(b.id) AS bid_count
FROM public."Club_Auction_Listings" l
JOIN public."Clubs" c ON c."ShortName" = l.club_short_name
LEFT JOIN public."Club_Auction_Bids" b ON b.listing_id = l.id
WHERE l.status = 'Active'
GROUP BY l.id, l.club_short_name, c."Capacity", l.opening_bid, l.current_highest_bid
HAVING min(b.bid_amount) IS NOT NULL
   AND min(b.bid_amount) < l.opening_bid
ORDER BY l.club_short_name;

-- Sample of shifted threads (high should be ≥ opening)
SELECT
  l.club_short_name,
  c."Capacity" AS capacity,
  l.opening_bid,
  l.current_highest_bid,
  count(b.id) AS bid_count
FROM public."Club_Auction_Listings" l
JOIN public."Clubs" c ON c."ShortName" = l.club_short_name
LEFT JOIN public."Club_Auction_Bids" b ON b.listing_id = l.id
WHERE l.status = 'Active'
GROUP BY l.club_short_name, c."Capacity", l.opening_bid, l.current_highest_bid
ORDER BY l.club_short_name
LIMIT 30;
