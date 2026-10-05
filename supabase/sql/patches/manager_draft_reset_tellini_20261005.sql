-- =============================================================================
-- Admin (one-off): reset the Sotirio Tellini manager draft auction.
-- Legacy test-season max bids pushed the price to ₿40m before real bidding.
--   • Removes every other club's bids + max bids on Tellini (Crvena zvezda and
--     the other club caught by the legacy auto-bids — both have moved on).
--   • Keeps dbyrne's club as the only bidder: its first bid is kept and set to
--     the ₿30m opening value; its later (inflated) bids are removed.
-- STEP 1 is read-only — run it first and check the rows. Then run STEP 2.
-- =============================================================================

-- STEP 1 (preview): all bids on Tellini, oldest first
SELECT b.id, b.bidder_club_id, c."Club", c.owner, b.bid_amount, b.bid_time,
       b.is_direct, b.is_first_draft_bid
FROM public."Manager_Transfer_Bids" b
JOIN public."Manager_Transfer_Listings" l ON l.id = b.listing_id
JOIN public."Managers" m ON m.id = l.manager_id
LEFT JOIN public."Clubs" c ON c."ShortName" = b.bidder_club_id
WHERE l.listing_type = 'draft' AND l.status = 'Active'
  AND m.name ILIKE '%tellini%'
ORDER BY b.bid_time;

-- STEP 2 (fix)
DO $$
DECLARE
  v_name text := 'Tellini';          -- <- manager name (partial match)
  v_keep_owner text := 'dbyrne';     -- <- owner tag of the club that stays in
  v_opening numeric := 30000000;     -- <- reset price

  v_keep_club text;
  v_mgr_id bigint;
  v_mgr_name text;
  v_listing public."Manager_Transfer_Listings"%rowtype;
  v_keep_bid bigint;
  v_other_bids int;
  v_other_max int;
  v_own_extra int;
BEGIN
  SELECT c."ShortName" INTO v_keep_club
  FROM public."Clubs" c
  WHERE c.owner ILIKE v_keep_owner || '%'
  ORDER BY c."ShortName"
  LIMIT 1;
  IF v_keep_club IS NULL THEN
    RAISE EXCEPTION 'No club found for owner %', v_keep_owner;
  END IF;

  SELECT m.id, m.name INTO v_mgr_id, v_mgr_name
  FROM public."Managers" m
  JOIN public."Manager_Transfer_Listings" l
    ON l.manager_id = m.id AND l.listing_type = 'draft' AND l.status = 'Active'
  WHERE m.name ILIKE '%' || v_name || '%'
  ORDER BY m.id
  LIMIT 1;
  IF v_mgr_id IS NULL THEN
    RAISE EXCEPTION 'No active manager draft listing for a manager matching %', v_name;
  END IF;

  SELECT * INTO v_listing
  FROM public."Manager_Transfer_Listings"
  WHERE manager_id = v_mgr_id AND listing_type = 'draft' AND status = 'Active'
  ORDER BY id
  LIMIT 1
  FOR UPDATE;

  SELECT b.id INTO v_keep_bid
  FROM public."Manager_Transfer_Bids" b
  WHERE b.listing_id = v_listing.id
    AND upper(btrim(b.bidder_club_id)) = upper(v_keep_club)
  ORDER BY b.bid_time ASC, b.id ASC
  LIMIT 1;
  IF v_keep_bid IS NULL THEN
    RAISE EXCEPTION '% (%) has no bid on % — nothing to keep', v_keep_club, v_keep_owner, v_mgr_name;
  END IF;

  DELETE FROM public."Manager_Transfer_Bids" b
  WHERE b.listing_id = v_listing.id
    AND upper(btrim(b.bidder_club_id)) <> upper(v_keep_club);
  GET DIAGNOSTICS v_other_bids = ROW_COUNT;

  DELETE FROM public.manager_draft_max_bids
  WHERE manager_id = v_mgr_id
    AND upper(btrim(club_short_name)) <> upper(v_keep_club);
  GET DIAGNOSTICS v_other_max = ROW_COUNT;

  DELETE FROM public."Manager_Transfer_Bids" b
  WHERE b.listing_id = v_listing.id
    AND upper(btrim(b.bidder_club_id)) = upper(v_keep_club)
    AND b.id <> v_keep_bid;
  GET DIAGNOSTICS v_own_extra = ROW_COUNT;

  UPDATE public."Manager_Transfer_Bids"
  SET bid_amount = v_opening,
      is_direct = true,
      is_first_draft_bid = true
  WHERE id = v_keep_bid;

  UPDATE public."Manager_Transfer_Listings"
  SET current_highest_bid = v_opening,
      current_highest_bidder = v_keep_club,
      updated_at = now()
  WHERE id = v_listing.id;

  RAISE NOTICE '% (listing %): removed % other-club bid(s) and % other-club max bid(s); removed % extra % bid(s). % now leads at %.',
    v_mgr_name, v_listing.id, v_other_bids, v_other_max, v_own_extra, v_keep_club, v_keep_club, v_opening;
END $$;

-- Check result (also shows dbyrne's own max bid, if he set one)
SELECT
  l.id AS listing_id,
  mg.name AS manager_name,
  l.current_highest_bidder AS leader_now,
  l.current_highest_bid,
  public.manager_draft_min_next_bid(l.manager_id) AS next_min_bid,
  (SELECT string_agg(b.bidder_club_id || ' ' || b.bid_amount::text, ', ' ORDER BY b.bid_amount DESC)
   FROM public."Manager_Transfer_Bids" b WHERE b.listing_id = l.id) AS bids,
  (SELECT string_agg(x.club_short_name || ' max ' || x.max_amount::text, ', ')
   FROM public.manager_draft_max_bids x WHERE x.manager_id = l.manager_id) AS max_bids
FROM public."Manager_Transfer_Listings" l
JOIN public."Managers" mg ON mg.id = l.manager_id
WHERE l.listing_type = 'draft'
  AND l.status = 'Active'
  AND mg.name ILIKE '%tellini%';
