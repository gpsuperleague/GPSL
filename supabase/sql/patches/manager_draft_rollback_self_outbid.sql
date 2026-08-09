-- =============================================================================
-- Rollback manager-draft self-outbids (+₿500k same club, no rival)
-- =============================================================================
-- Stronger than the DO block in manager_draft_no_self_outbid.sql:
-- matches by manager_id, tolerates numeric noise, returns JSON of removals.
--
-- Run in Supabase SQL Editor, then hard-refresh the auction page.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_rollback_manager_draft_self_outbids()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_mgr record;
  v_top record;
  v_prev record;
  v_rival int;
  v_removed int := 0;
  v_details jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR v_mgr IN
    SELECT DISTINCT l.manager_id, l.id AS listing_id, m.name AS manager_name
    FROM public."Manager_Transfer_Listings" l
    JOIN public."Managers" m ON m.id = l.manager_id
    WHERE l.listing_type = 'draft'
      AND l.status = 'Active'
  LOOP
    SELECT b.id, b.bid_amount, b.bidder_club_id, b.listing_id, b.bid_time
    INTO v_top
    FROM public."Manager_Transfer_Bids" b
    WHERE b.manager_id = v_mgr.manager_id
      AND coalesce(b.is_direct, true) = true
    ORDER BY b.bid_amount DESC, b.bid_time DESC, b.id DESC
    LIMIT 1;

    CONTINUE WHEN v_top.id IS NULL;

    SELECT b.id, b.bid_amount, b.bidder_club_id, b.listing_id, b.bid_time
    INTO v_prev
    FROM public."Manager_Transfer_Bids" b
    WHERE b.manager_id = v_mgr.manager_id
      AND coalesce(b.is_direct, true) = true
      AND b.id <> v_top.id
    ORDER BY b.bid_amount DESC, b.bid_time DESC, b.id DESC
    LIMIT 1;

    CONTINUE WHEN v_prev.id IS NULL;

    SELECT count(*)::int INTO v_rival
    FROM public."Manager_Transfer_Bids" b
    WHERE b.manager_id = v_mgr.manager_id
      AND coalesce(b.is_direct, true) = true
      AND upper(btrim(b.bidder_club_id))
            IS DISTINCT FROM upper(btrim(v_top.bidder_club_id));

    IF v_rival > 0 THEN
      CONTINUE;
    END IF;

    IF upper(btrim(v_top.bidder_club_id)) <> upper(btrim(v_prev.bidder_club_id)) THEN
      CONTINUE;
    END IF;

    -- Self-raise of exactly one increment (₿500,000), allow 1 unit float noise
    IF abs(v_top.bid_amount - (v_prev.bid_amount + 500000)) > 1 THEN
      CONTINUE;
    END IF;

    DELETE FROM public."Manager_Transfer_Bids" WHERE id = v_top.id;

    UPDATE public."Manager_Transfer_Listings" l
    SET current_highest_bid = v_prev.bid_amount,
        current_highest_bidder = v_prev.bidder_club_id
    WHERE l.manager_id = v_mgr.manager_id
      AND l.listing_type = 'draft'
      AND l.status = 'Active';

    v_removed := v_removed + 1;
    v_details := v_details || jsonb_build_array(jsonb_build_object(
      'manager_id', v_mgr.manager_id,
      'manager', v_mgr.manager_name,
      'club', v_top.bidder_club_id,
      'removed_bid_id', v_top.id,
      'removed_amount', v_top.bid_amount,
      'restored_amount', v_prev.bid_amount
    ));
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'removed', v_removed,
    'details', v_details
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_rollback_manager_draft_self_outbids() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Diagnose first (what looks like a self-outbid)
SELECT
  m.name,
  b.bidder_club_id,
  b.bid_amount,
  b.bid_time,
  b.id AS bid_id,
  l.id AS listing_id,
  l.current_highest_bid,
  l.current_highest_bidder
FROM public."Manager_Transfer_Bids" b
JOIN public."Managers" m ON m.id = b.manager_id
LEFT JOIN public."Manager_Transfer_Listings" l
  ON l.manager_id = b.manager_id
 AND l.listing_type = 'draft'
 AND l.status = 'Active'
WHERE coalesce(b.is_direct, true) = true
  AND b.manager_id IN (
    SELECT manager_id
    FROM public."Manager_Transfer_Listings"
    WHERE listing_type = 'draft' AND status = 'Active'
  )
ORDER BY m.name, b.bid_amount DESC, b.bid_time DESC;

-- Rollback
SELECT public.admin_rollback_manager_draft_self_outbids();

-- Confirm
SELECT
  m.name,
  l.current_highest_bid,
  l.current_highest_bidder,
  (
    SELECT jsonb_agg(jsonb_build_object(
      'club', b.bidder_club_id,
      'amount', b.bid_amount,
      'id', b.id
    ) ORDER BY b.bid_amount DESC)
    FROM public."Manager_Transfer_Bids" b
    WHERE b.manager_id = l.manager_id
      AND coalesce(b.is_direct, true)
  ) AS bids
FROM public."Manager_Transfer_Listings" l
JOIN public."Managers" m ON m.id = l.manager_id
WHERE l.listing_type = 'draft'
  AND l.status = 'Active'
ORDER BY m.name;
