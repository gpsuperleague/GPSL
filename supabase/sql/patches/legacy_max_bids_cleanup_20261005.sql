-- =============================================================================
-- Cleanup: legacy (test-season) max / auto bids + guard against re-use
-- =============================================================================
-- Max bids can only be SET while a draft window is open, so any max bid whose
-- updated_at is before the current window's start is left over from an
-- earlier (test) draft. Those were firing auto-bids in the live manager draft.
--
-- 1) Manager draft: for every club holding a legacy max bid on a manager with
--    an ACTIVE draft listing, remove that club's bids on that manager placed in
--    the current window (the auto-bids), then recompute the listing leader from
--    the remaining bids and let genuine (current) max bids respond.
-- 2) Delete all legacy manager + player draft max bids.
-- 3) Guard: resolvers ignore any max bid set before the current window start.
--
-- Run legacy_max_bids_check_20261005.sql first and review query 2 — a club that
-- ALSO bid by hand on the same manager will have those bids removed too.
-- Safe re-run.
-- =============================================================================

DO $cleanup$
DECLARE
  wb record;
  r record;
  v_deleted int;
  v_top record;
  v_auto int;
  v_total_bids int := 0;
  v_listings int := 0;
  v_mgr_max int;
  v_player_max int;
BEGIN
  SELECT * INTO wb FROM public.manager_draft_auction_window_bounds();

  IF wb.draft_start IS NOT NULL THEN
    FOR r IN
      SELECT DISTINCT l.id AS listing_id, l.manager_id, m.club_short_name
      FROM public.manager_draft_max_bids m
      JOIN public."Manager_Transfer_Listings" l
        ON l.manager_id = m.manager_id
       AND l.listing_type = 'draft'
       AND l.status = 'Active'
      WHERE m.updated_at < wb.draft_start
    LOOP
      DELETE FROM public."Manager_Transfer_Bids" b
      WHERE b.listing_id = r.listing_id
        AND b.is_direct = true
        AND upper(btrim(b.bidder_club_id)) = upper(btrim(r.club_short_name))
        AND b.bid_time >= wb.draft_start;
      GET DIAGNOSTICS v_deleted = ROW_COUNT;

      CONTINUE WHEN v_deleted = 0;
      v_total_bids := v_total_bids + v_deleted;
      v_listings := v_listings + 1;

      SELECT b.bidder_club_id, b.bid_amount INTO v_top
      FROM public."Manager_Transfer_Bids" b
      WHERE b.listing_id = r.listing_id
        AND b.is_direct = true
        AND b.bid_time >= wb.draft_start
      ORDER BY b.bid_amount DESC, b.bid_time ASC
      LIMIT 1;

      UPDATE public."Manager_Transfer_Listings"
      SET current_highest_bid = v_top.bid_amount,
          current_highest_bidder = v_top.bidder_club_id,
          updated_at = now()
      WHERE id = r.listing_id;

      RAISE NOTICE 'Manager % (listing %): removed % auto-bid(s) by %. Leader now % at %',
        r.manager_id, r.listing_id, v_deleted, r.club_short_name,
        coalesce(v_top.bidder_club_id, 'none'), coalesce(v_top.bid_amount::text, 'no bids');
    END LOOP;

    DELETE FROM public.manager_draft_max_bids WHERE updated_at < wb.draft_start;
  ELSE
    DELETE FROM public.manager_draft_max_bids;
  END IF;
  GET DIAGNOSTICS v_mgr_max = ROW_COUNT;

  SELECT * INTO wb FROM public.draft_auction_window_bounds();
  IF wb.draft_start IS NOT NULL THEN
    DELETE FROM public.player_draft_max_bids WHERE updated_at < wb.draft_start;
  ELSE
    DELETE FROM public.player_draft_max_bids;
  END IF;
  GET DIAGNOSTICS v_player_max = ROW_COUNT;

  RAISE NOTICE 'Removed % auto-bid(s) across % manager listing(s); deleted % legacy manager max bid(s) and % legacy player max bid(s)',
    v_total_bids, v_listings, v_mgr_max, v_player_max;
END;
$cleanup$;

-- Let genuine current-window max bids respond on the tidied listings
DO $reresolve$
DECLARE
  r record;
  v_n int;
BEGIN
  FOR r IN
    SELECT DISTINCT m.manager_id
    FROM public.manager_draft_max_bids m
    JOIN public."Manager_Transfer_Listings" l
      ON l.manager_id = m.manager_id
     AND l.listing_type = 'draft'
     AND l.status = 'Active'
  LOOP
    BEGIN
      v_n := public.manager_draft_resolve_max_bids(r.manager_id);
      IF v_n > 0 THEN
        RAISE NOTICE 'Manager %: % proxy bid(s) placed by current max bids', r.manager_id, v_n;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Manager % re-resolve failed: %', r.manager_id, SQLERRM;
    END;
  END LOOP;
END;
$reresolve$;

-- Guard: ignore max bids set before the current window (both resolvers)
DO $guard$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef('public.manager_draft_resolve_max_bids(bigint)'::regprocedure) INTO v_def;
  IF position('m.updated_at >= v_bounds.draft_start' IN v_def) > 0 THEN
    RAISE NOTICE 'Manager resolver guard already present';
  ELSIF position('WHERE m.manager_id = p_manager_id' IN v_def) = 0 THEN
    RAISE WARNING 'Manager resolver: anchor not found — guard NOT applied';
  ELSE
    EXECUTE replace(
      v_def,
      'WHERE m.manager_id = p_manager_id',
      'WHERE m.manager_id = p_manager_id AND m.updated_at >= v_bounds.draft_start'
    );
    RAISE NOTICE 'Manager resolver guard applied';
  END IF;

  SELECT pg_get_functiondef('public.player_draft_resolve_max_bids(text)'::regprocedure) INTO v_def;
  IF position('m.updated_at >= v_bounds.draft_start' IN v_def) > 0 THEN
    RAISE NOTICE 'Player resolver guard already present';
  ELSIF position('WHERE m.player_id = v_pid' IN v_def) = 0 THEN
    RAISE WARNING 'Player resolver: anchor not found — guard NOT applied';
  ELSE
    EXECUTE replace(
      v_def,
      'WHERE m.player_id = v_pid',
      'WHERE m.player_id = v_pid AND m.updated_at >= v_bounds.draft_start'
    );
    RAISE NOTICE 'Player resolver guard applied';
  END IF;
END;
$guard$;

NOTIFY pgrst, 'reload schema';

-- Result: active manager draft listings
SELECT
  l.id AS listing_id,
  mg.name AS manager_name,
  coalesce(l.current_highest_bidder, '— no bids —') AS leader_now,
  l.current_highest_bid,
  public.manager_draft_min_next_bid(l.manager_id) AS next_min_bid
FROM public."Manager_Transfer_Listings" l
JOIN public."Managers" mg ON mg.id = l.manager_id
WHERE l.listing_type = 'draft'
  AND l.status = 'Active'
ORDER BY mg.name;
