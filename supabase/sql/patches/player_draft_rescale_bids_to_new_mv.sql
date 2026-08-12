-- =============================================================================
-- APPLY: rescale Active player-draft bids to new market values
-- =============================================================================
-- Prerequisite: Players.market_value already recalculated (base table + apply).
--
-- Scope: Active draft listings (seller_club_id NULL) where
--   listing.market_value IS DISTINCT FROM Players.market_value
-- Threads already on the new MV snapshot are left alone.
--
-- Per listing:
--   old_open = first bid (is_first_draft_bid / earliest), else listing.market_value
--   new_open = Players.market_value
--   ratio    = new_open / old_open
--   • first bid amount  → exactly new_open
--   • every other bid   → round(bid_amount × ratio)
--   • listing.market_value + reserve_price → new_open
--   • current_highest_* refreshed from bids
--   • player_draft_max_bids.max_amount × ratio for that player_id
--
-- Closed / settled listings are not touched.
-- Idempotent: after a successful run, listing MV matches Players MV → skip.
--
-- Run preview first: player_draft_rescale_bids_to_new_mv_preview.sql
-- =============================================================================

DO $$
DECLARE
  r record;
  v_old_open numeric;
  v_new_open numeric;
  v_ratio numeric;
  v_first_bid_id bigint;
  v_new_high numeric;
  v_new_bidder text;
  v_n int;
  v_listings int := 0;
  v_bids int := 0;
  v_maxes int := 0;
  v_listings_mv_only int := 0;
BEGIN
  FOR r IN
    SELECT
      l.id AS listing_id,
      btrim(l.player_id::text) AS player_id,
      nullif(btrim(l.market_value::text), '')::numeric AS listing_mv,
      nullif(btrim(p.market_value::text), '')::numeric AS player_mv,
      coalesce(p."Name"::text, l.player_id::text) AS player_name
    FROM public."Player_Transfer_Listings" l
    JOIN public."Players" p
      ON btrim(p."Konami_ID"::text) = btrim(l.player_id::text)
    WHERE l.listing_type = 'draft'
      AND l.status = 'Active'
      AND l.seller_club_id IS NULL
      AND nullif(btrim(p.market_value::text), '')::numeric IS NOT NULL
      AND nullif(btrim(p.market_value::text), '')::numeric > 0
      AND nullif(btrim(l.market_value::text), '')::numeric
            IS DISTINCT FROM nullif(btrim(p.market_value::text), '')::numeric
    ORDER BY l.id
  LOOP
    v_new_open := r.player_mv;
    v_first_bid_id := NULL;
    v_old_open := NULL;

    SELECT b.bid_id, b.bid_amount::numeric
    INTO v_first_bid_id, v_old_open
    FROM public."Player_Transfer_Bids" b
    WHERE b.listing_id = r.listing_id
    ORDER BY
      CASE WHEN coalesce(b.is_first_draft_bid, false) THEN 0 ELSE 1 END,
      b.bid_time ASC NULLS LAST,
      b.bid_id ASC
    LIMIT 1;

    IF v_old_open IS NULL OR v_old_open <= 0 THEN
      v_old_open := r.listing_mv;
    END IF;

    IF v_old_open IS NULL OR v_old_open <= 0 THEN
      RAISE NOTICE 'Skip % (%) — no old opening to ratio from', r.player_name, r.player_id;
      CONTINUE;
    END IF;

    -- Listing snapshot only (no bids yet)
    IF v_first_bid_id IS NULL THEN
      UPDATE public."Player_Transfer_Listings" l
      SET
        market_value = v_new_open,
        reserve_price = v_new_open,
        current_highest_bid = CASE
          WHEN l.current_highest_bid IS NULL THEN NULL
          ELSE v_new_open
        END
      WHERE l.id = r.listing_id;

      IF to_regclass('public.player_draft_max_bids') IS NOT NULL
         AND v_old_open IS DISTINCT FROM v_new_open THEN
        v_ratio := v_new_open / v_old_open;
        UPDATE public.player_draft_max_bids m
        SET
          max_amount = round(m.max_amount * v_ratio),
          updated_at = now()
        WHERE btrim(m.player_id::text) = r.player_id
          AND m.max_amount IS NOT NULL
          AND m.max_amount > 0;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        v_maxes := v_maxes + v_n;
      END IF;

      v_listings_mv_only := v_listings_mv_only + 1;
      v_listings := v_listings + 1;
      CONTINUE;
    END IF;

    IF v_old_open = v_new_open THEN
      UPDATE public."Player_Transfer_Listings" l
      SET market_value = v_new_open,
          reserve_price = v_new_open
      WHERE l.id = r.listing_id;
      CONTINUE;
    END IF;

    v_ratio := v_new_open / v_old_open;

    UPDATE public."Player_Transfer_Bids" b
    SET bid_amount = CASE
      WHEN b.bid_id = v_first_bid_id THEN v_new_open
      ELSE round(b.bid_amount::numeric * v_ratio)
    END
    WHERE b.listing_id = r.listing_id;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_bids := v_bids + v_n;

    -- Leader matches live UI (amount DESC, time DESC)
    SELECT b.bid_amount::numeric, b.bidder_club_id::text
    INTO v_new_high, v_new_bidder
    FROM public."Player_Transfer_Bids" b
    WHERE b.listing_id = r.listing_id
    ORDER BY b.bid_amount DESC NULLS LAST, b.bid_time DESC NULLS LAST, b.bid_id DESC
    LIMIT 1;

    UPDATE public."Player_Transfer_Listings" l
    SET
      market_value = v_new_open,
      reserve_price = v_new_open,
      current_highest_bid = v_new_high,
      current_highest_bidder = v_new_bidder
    WHERE l.id = r.listing_id;

    IF to_regclass('public.player_draft_max_bids') IS NOT NULL THEN
      UPDATE public.player_draft_max_bids m
      SET
        max_amount = round(m.max_amount * v_ratio),
        updated_at = now()
      WHERE btrim(m.player_id::text) = r.player_id
        AND m.max_amount IS NOT NULL
        AND m.max_amount > 0;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      v_maxes := v_maxes + v_n;
    END IF;

    v_listings := v_listings + 1;

    RAISE NOTICE
      'Rescaled % (%) open % → % (ratio %), high → %',
      r.player_name,
      r.player_id,
      to_char(v_old_open, 'FM999,999,999,999'),
      to_char(v_new_open, 'FM999,999,999,999'),
      to_char(round(v_ratio, 4), 'FM990.0000'),
      to_char(coalesce(v_new_high, v_new_open), 'FM999,999,999,999');
  END LOOP;

  RAISE NOTICE
    'Done. listings=% (mv_only_no_bids=%), bids_updated=%, maxes_updated=%',
    v_listings, v_listings_mv_only, v_bids, v_maxes;
END $$;

NOTIFY pgrst, 'reload schema';

-- Verify: Active draft threads still mismatched vs Players MV (should be 0)
SELECT
  l.id AS listing_id,
  l.player_id,
  p."Name",
  nullif(btrim(l.market_value::text), '')::numeric AS listing_mv,
  nullif(btrim(p.market_value::text), '')::numeric AS player_mv,
  l.current_highest_bid,
  (
    SELECT min(b.bid_amount)::numeric
    FROM public."Player_Transfer_Bids" b
    WHERE b.listing_id = l.id
  ) AS lowest_bid,
  (
    SELECT max(b.bid_amount)::numeric
    FROM public."Player_Transfer_Bids" b
    WHERE b.listing_id = l.id
  ) AS highest_bid
FROM public."Player_Transfer_Listings" l
JOIN public."Players" p
  ON btrim(p."Konami_ID"::text) = btrim(l.player_id::text)
WHERE l.listing_type = 'draft'
  AND l.status = 'Active'
  AND l.seller_club_id IS NULL
  AND nullif(btrim(l.market_value::text), '')::numeric
        IS DISTINCT FROM nullif(btrim(p.market_value::text), '')::numeric
ORDER BY p."Name"
LIMIT 50;

-- Sample of rescaled Active draft threads
SELECT
  p."Name",
  l.player_id,
  nullif(btrim(l.market_value::text), '')::numeric AS listing_mv,
  l.current_highest_bid,
  l.current_highest_bidder,
  count(b.bid_id)::int AS bid_count,
  min(b.bid_amount)::numeric AS min_bid,
  max(b.bid_amount)::numeric AS max_bid
FROM public."Player_Transfer_Listings" l
JOIN public."Players" p
  ON btrim(p."Konami_ID"::text) = btrim(l.player_id::text)
LEFT JOIN public."Player_Transfer_Bids" b ON b.listing_id = l.id
WHERE l.listing_type = 'draft'
  AND l.status = 'Active'
  AND l.seller_club_id IS NULL
GROUP BY
  p."Name", l.player_id, l.market_value, l.current_highest_bid, l.current_highest_bidder, l.id
ORDER BY p."Name"
LIMIT 40;
