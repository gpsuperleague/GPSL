-- =============================================================================
-- Admin: withdraw Wortho8 (PSG) from the Cristo Valbuena manager draft auction
-- (one-off). Removes all PSG bids + PSG max bid on that manager and any
-- test-season max bids on that manager, recomputes the leader from the
-- remaining current-window bids, then lets other clubs' current max bids
-- respond. Run once in the Supabase SQL Editor.
-- =============================================================================

DO $$
DECLARE
  v_club text := 'PSG';          -- <- club withdrawing
  v_name text := 'Valbuena';     -- <- manager name (partial match)

  v_mgr_id bigint;
  v_mgr_name text;
  v_listing public."Manager_Transfer_Listings"%rowtype;
  wb record;
  v_deleted int;
  v_max_deleted int;
  v_top record;
  v_auto int := 0;
BEGIN
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

  SELECT * INTO wb FROM public.manager_draft_auction_window_bounds();

  DELETE FROM public."Manager_Transfer_Bids" b
  WHERE b.listing_id = v_listing.id
    AND upper(btrim(b.bidder_club_id)) = upper(v_club);
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  DELETE FROM public.manager_draft_max_bids
  WHERE manager_id = v_mgr_id
    AND upper(btrim(club_short_name)) = upper(v_club);
  GET DIAGNOSTICS v_max_deleted = ROW_COUNT;

  -- Test-season max bids on this manager must not re-fire below
  IF wb.draft_start IS NOT NULL THEN
    DELETE FROM public.manager_draft_max_bids
    WHERE manager_id = v_mgr_id
      AND updated_at < wb.draft_start;
  END IF;

  SELECT b.bidder_club_id, b.bid_amount INTO v_top
  FROM public."Manager_Transfer_Bids" b
  WHERE b.listing_id = v_listing.id
    AND b.is_direct = true
    AND (wb.draft_start IS NULL OR b.bid_time >= wb.draft_start)
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  UPDATE public."Manager_Transfer_Listings"
  SET current_highest_bid = v_top.bid_amount,
      current_highest_bidder = v_top.bidder_club_id,
      updated_at = now()
  WHERE id = v_listing.id;

  BEGIN
    v_auto := public.manager_draft_resolve_max_bids(v_mgr_id);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Re-resolve max bids failed: %', SQLERRM;
  END;

  RAISE NOTICE 'Withdrew % bid(s) and % max bid(s) by % on % (listing %). Leader now % at %. Proxy bids placed after: %',
    v_deleted, v_max_deleted, v_club, v_mgr_name, v_listing.id,
    coalesce(v_top.bidder_club_id, 'none'),
    coalesce(v_top.bid_amount::text, 'no bids'),
    v_auto;
END $$;

-- Check result
SELECT
  l.id AS listing_id,
  mg.name AS manager_name,
  coalesce(l.current_highest_bidder, '— no bids —') AS leader_now,
  l.current_highest_bid,
  public.manager_draft_min_next_bid(l.manager_id) AS next_min_bid,
  (SELECT count(*) FROM public."Manager_Transfer_Bids" b WHERE b.listing_id = l.id) AS bids_remaining,
  (SELECT string_agg(b.bidder_club_id || ' ' || b.bid_amount::text, ', ' ORDER BY b.bid_amount DESC)
   FROM public."Manager_Transfer_Bids" b WHERE b.listing_id = l.id) AS bids
FROM public."Manager_Transfer_Listings" l
JOIN public."Managers" mg ON mg.id = l.manager_id
WHERE l.listing_type = 'draft'
  AND l.status = 'Active'
  AND mg.name ILIKE '%valbuena%';
