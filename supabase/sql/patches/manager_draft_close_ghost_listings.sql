-- =============================================================================
-- Close ghost manager draft listings (empty Active shells)
-- =============================================================================
-- Symptom: managers appear on manager_draftauction.html with Highest Bid / Leading
-- Club / Owner all "—". Usually ensure_listing ran, then bid/max-bid failed.
--
-- This script:
--   A) Shows the 5 (and any other empty Active draft listings)
--   B) If a max_bid exists with no bid row → place opening auto-bid (restore)
--   C) Else if bid rows exist → sync high-bid onto listing
--   D) Else → Close the ghost listing (removes from the page)
--
-- Run in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_cleanup_manager_draft_ghost_listings()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_min numeric;
  v_result jsonb;
  v_restored int := 0;
  v_synced int := 0;
  v_closed int := 0;
  v_details jsonb := '[]'::jsonb;
  v_top_amt numeric;
  v_top_club text;
  v_max_club text;
  v_max_amt numeric;
  v_bid_count int;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR v_row IN
    SELECT
      l.id AS listing_id,
      l.manager_id,
      m.name AS manager_name,
      l.current_highest_bid,
      l.current_highest_bidder
    FROM public."Manager_Transfer_Listings" l
    JOIN public."Managers" m ON m.id = l.manager_id
    WHERE l.listing_type = 'draft'
      AND l.status = 'Active'
      AND (
        l.current_highest_bid IS NULL
        OR nullif(btrim(coalesce(l.current_highest_bidder, '')), '') IS NULL
      )
    ORDER BY m.name
  LOOP
    SELECT count(*)::int INTO v_bid_count
    FROM public."Manager_Transfer_Bids" b
    WHERE b.manager_id = v_row.manager_id
      AND b.is_direct = true;

    SELECT b.bid_amount, b.bidder_club_id
    INTO v_top_amt, v_top_club
    FROM public."Manager_Transfer_Bids" b
    WHERE b.manager_id = v_row.manager_id
      AND b.is_direct = true
    ORDER BY b.bid_amount DESC, b.bid_time ASC
    LIMIT 1;

    SELECT mb.club_short_name, mb.max_amount
    INTO v_max_club, v_max_amt
    FROM public.manager_draft_max_bids mb
    WHERE mb.manager_id = v_row.manager_id
    ORDER BY mb.max_amount DESC, mb.updated_at ASC
    LIMIT 1;

    -- 1) Bid rows exist but listing blank → sync
    IF v_top_club IS NOT NULL THEN
      UPDATE public."Manager_Transfer_Listings"
      SET current_highest_bid = v_top_amt,
          current_highest_bidder = v_top_club
      WHERE id = v_row.listing_id;
      v_synced := v_synced + 1;
      v_details := v_details || jsonb_build_array(jsonb_build_object(
        'manager', v_row.manager_name,
        'listing_id', v_row.listing_id,
        'action', 'synced_from_bids',
        'bid', v_top_amt,
        'club', v_top_club
      ));
      CONTINUE;
    END IF;

    -- 2) Max bid saved, no bid row → try restore auto-bid
    IF v_max_club IS NOT NULL
       AND public.manager_draft_bidding_open_now()
       AND NOT EXISTS (
         SELECT 1 FROM public."Manager_Transfer_Listings" l2
         WHERE l2.listing_type = 'draft'
           AND l2.status = 'Active'
           AND l2.current_highest_bidder = v_max_club
           AND l2.manager_id <> v_row.manager_id
       ) THEN
      BEGIN
        v_min := public.manager_draft_min_next_bid(v_row.manager_id);
        IF v_min IS NOT NULL AND v_min <= v_max_amt THEN
          v_result := public.manager_draft_place_auto_bid(
            v_max_club, v_row.manager_id, v_min
          );
          IF coalesce((v_result->>'ok')::boolean, false)
             AND coalesce(v_result->>'skipped', '') = '' THEN
            v_restored := v_restored + 1;
            PERFORM public.manager_draft_resolve_max_bids(v_row.manager_id);
            v_details := v_details || jsonb_build_array(jsonb_build_object(
              'manager', v_row.manager_name,
              'listing_id', v_row.listing_id,
              'action', 'restored_from_max_bid',
              'club', v_max_club,
              'bid', v_min
            ));
            CONTINUE;
          END IF;
        END IF;
      EXCEPTION WHEN OTHERS THEN
        NULL; -- fall through to close
      END;
    END IF;

    -- 3) True ghost — close so it leaves the auction board
    UPDATE public."Manager_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = coalesce(transfer_completed, false),
        updated_at = now()
    WHERE id = v_row.listing_id
      AND status = 'Active';

    v_closed := v_closed + 1;
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'manager', v_row.manager_name,
      'listing_id', v_row.listing_id,
      'action', 'closed_ghost',
      'had_bid_rows', v_bid_count,
      'had_max_bid', v_max_club IS NOT NULL,
      'max_club', v_max_club
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'synced_from_bids', v_synced,
    'restored_from_max_bid', v_restored,
    'closed_ghosts', v_closed,
    'details', v_details
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_cleanup_manager_draft_ghost_listings() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Before
SELECT
  l.id,
  m.name,
  l.status,
  l.current_highest_bid,
  l.current_highest_bidder,
  (SELECT count(*) FROM public."Manager_Transfer_Bids" b
   WHERE b.manager_id = l.manager_id AND b.is_direct) AS bids,
  (SELECT mb.club_short_name || ' @ ' || mb.max_amount::text
   FROM public.manager_draft_max_bids mb
   WHERE mb.manager_id = l.manager_id
   ORDER BY mb.max_amount DESC LIMIT 1) AS max_bid
FROM public."Manager_Transfer_Listings" l
JOIN public."Managers" m ON m.id = l.manager_id
WHERE l.listing_type = 'draft'
  AND l.status = 'Active'
  AND m.name IN (
    'Dino Millesi',
    'Luis A. Roman',
    'Mikel Arteta',
    'Fran Cudoreni',
    'Gas Odrozola'
  )
ORDER BY m.name;

-- Cleanup
SELECT public.admin_cleanup_manager_draft_ghost_listings();

-- After — should be empty (closed) or show a real high bid
SELECT
  l.id,
  m.name,
  l.status,
  l.current_highest_bid,
  l.current_highest_bidder
FROM public."Manager_Transfer_Listings" l
JOIN public."Managers" m ON m.id = l.manager_id
WHERE l.listing_type = 'draft'
  AND m.name IN (
    'Dino Millesi',
    'Luis A. Roman',
    'Mikel Arteta',
    'Fran Cudoreni',
    'Gas Odrozola'
  )
ORDER BY m.name, l.id DESC;
