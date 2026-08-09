-- =============================================================================
-- Backfill: manager draft auctions stuck with bids / max-bids but blank UI
-- =============================================================================
-- After manager_draft_max_bid_window_fix.sql:
--   1) Sync listing high-bid from ANY direct bid rows (ignore window)
--   2) For max_bids that never created a bid (400 bug), place opening auto-bid
--
-- Run in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_repair_manager_draft_listing_high_bids()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_updated int := 0;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  -- Prefer bids on this listing_id; else any direct bid for that manager
  FOR v_row IN
    SELECT
      l.id AS listing_id,
      b.bid_amount,
      b.bidder_club_id
    FROM public."Manager_Transfer_Listings" l
    JOIN LATERAL (
      SELECT b2.bid_amount, b2.bidder_club_id
      FROM public."Manager_Transfer_Bids" b2
      WHERE b2.is_direct = true
        AND (
          b2.listing_id = l.id
          OR b2.manager_id = l.manager_id
        )
      ORDER BY
        CASE WHEN b2.listing_id = l.id THEN 0 ELSE 1 END,
        b2.bid_amount DESC,
        b2.bid_time ASC
      LIMIT 1
    ) b ON true
    WHERE l.listing_type = 'draft'
      AND l.status = 'Active'
      AND (
        l.current_highest_bid IS DISTINCT FROM b.bid_amount
        OR nullif(btrim(l.current_highest_bidder), '') IS DISTINCT FROM b.bidder_club_id
      )
  LOOP
    UPDATE public."Manager_Transfer_Listings"
    SET current_highest_bid = v_row.bid_amount,
        current_highest_bidder = v_row.bidder_club_id
    WHERE id = v_row.listing_id;
    v_updated := v_updated + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'listings_synced', v_updated);
END;
$function$;

-- Place missing opening bids from saved max_bids (max set but 400 blocked auto-bid)
CREATE OR REPLACE FUNCTION public.admin_backfill_manager_draft_max_bids()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_min numeric;
  v_result jsonb;
  v_placed int := 0;
  v_skipped int := 0;
  v_errors jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF NOT public.manager_draft_bidding_open_now() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'manager_draft_not_open',
      'hint', 'Turn manager draft on / keep schedule open, then re-run.'
    );
  END IF;

  FOR v_row IN
    SELECT
      m.manager_id,
      m.club_short_name,
      m.max_amount,
      mgr.name AS manager_name
    FROM public.manager_draft_max_bids m
    JOIN public."Managers" mgr ON mgr.id = m.manager_id
    WHERE mgr.contracted_club IS NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public."Manager_Transfer_Bids" b
        WHERE b.manager_id = m.manager_id
          AND b.bidder_club_id = m.club_short_name
          AND b.is_direct = true
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public."Manager_Transfer_Listings" l
        WHERE l.listing_type = 'draft'
          AND l.status = 'Active'
          AND l.current_highest_bidder = m.club_short_name
          AND l.manager_id <> m.manager_id
      )
    ORDER BY m.updated_at ASC
  LOOP
    BEGIN
      PERFORM public.manager_draft_ensure_listing(v_row.manager_id);
      v_min := public.manager_draft_min_next_bid(v_row.manager_id);

      IF v_min IS NULL OR v_min > v_row.max_amount THEN
        v_skipped := v_skipped + 1;
        CONTINUE;
      END IF;

      v_result := public.manager_draft_place_auto_bid(
        v_row.club_short_name,
        v_row.manager_id,
        v_min
      );

      IF coalesce((v_result->>'ok')::boolean, false)
         AND coalesce(v_result->>'skipped', '') = '' THEN
        v_placed := v_placed + 1;
        PERFORM public.manager_draft_resolve_max_bids(v_row.manager_id);
      ELSE
        v_skipped := v_skipped + 1;
        v_errors := v_errors || jsonb_build_array(
          jsonb_build_object(
            'manager_id', v_row.manager_id,
            'club', v_row.club_short_name,
            'result', v_result
          )
        );
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_skipped := v_skipped + 1;
      v_errors := v_errors || jsonb_build_array(
        jsonb_build_object(
          'manager_id', v_row.manager_id,
          'club', v_row.club_short_name,
          'error', SQLERRM
        )
      );
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'auto_bids_placed', v_placed,
    'skipped', v_skipped,
    'details', v_errors
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_repair_manager_draft_listing_high_bids() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_backfill_manager_draft_max_bids() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Diagnose (before)
-- ---------------------------------------------------------------------------
SELECT
  l.id AS listing_id,
  m.name,
  l.current_highest_bid,
  l.current_highest_bidder,
  (
    SELECT count(*)::int
    FROM public."Manager_Transfer_Bids" b
    WHERE b.manager_id = l.manager_id AND b.is_direct = true
  ) AS bid_rows,
  (
    SELECT max(b.bid_amount)
    FROM public."Manager_Transfer_Bids" b
    WHERE b.manager_id = l.manager_id AND b.is_direct = true
  ) AS max_bid_in_table
FROM public."Manager_Transfer_Listings" l
JOIN public."Managers" m ON m.id = l.manager_id
WHERE l.listing_type = 'draft'
  AND l.status = 'Active'
ORDER BY l.id;

SELECT
  mb.manager_id,
  mgr.name,
  mb.club_short_name,
  mb.max_amount,
  EXISTS (
    SELECT 1 FROM public."Manager_Transfer_Bids" b
    WHERE b.manager_id = mb.manager_id
      AND b.bidder_club_id = mb.club_short_name
      AND b.is_direct = true
  ) AS has_bid_row
FROM public.manager_draft_max_bids mb
JOIN public."Managers" mgr ON mgr.id = mb.manager_id
ORDER BY mb.updated_at DESC;

-- ---------------------------------------------------------------------------
-- Backfill
-- ---------------------------------------------------------------------------
SELECT public.admin_repair_manager_draft_listing_high_bids() AS sync_high_bids;
SELECT public.admin_backfill_manager_draft_max_bids() AS place_missing_max_bids;
SELECT public.admin_repair_manager_draft_listing_high_bids() AS sync_high_bids_again;

-- ---------------------------------------------------------------------------
-- Confirm (after)
-- ---------------------------------------------------------------------------
SELECT
  l.id AS listing_id,
  m.name,
  l.current_highest_bid,
  l.current_highest_bidder,
  (
    SELECT count(*)::int
    FROM public."Manager_Transfer_Bids" b
    WHERE b.manager_id = l.manager_id AND b.is_direct = true
  ) AS bid_rows
FROM public."Manager_Transfer_Listings" l
JOIN public."Managers" m ON m.id = l.manager_id
WHERE l.listing_type = 'draft'
  AND l.status = 'Active'
  AND (
    l.current_highest_bid IS NOT NULL
    OR EXISTS (
      SELECT 1 FROM public."Manager_Transfer_Bids" b
      WHERE b.manager_id = l.manager_id AND b.is_direct = true
    )
  )
ORDER BY l.current_highest_bid DESC NULLS LAST, m.name;
