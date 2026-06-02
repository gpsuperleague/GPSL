-- =============================================================================
-- Admin: reset draft auction (run once in SQL Editor)
-- Fixes "Reset Draft Auction" in admin.html when RLS blocks client deletes
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_reset_draft_auction()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_email text;
BEGIN
  v_email := coalesce(auth.jwt() ->> 'email', '');

  IF v_email <> 'rotavator66@outlook.com' THEN
    RAISE EXCEPTION 'Not authorized to reset draft auction';
  END IF;

  DELETE FROM "Player_Transfer_Bids"
  WHERE listing_id IN (
    SELECT id FROM "Player_Transfer_Listings" WHERE listing_type = 'draft'
  );

  DELETE FROM "Player_Transfer_Bids"
  WHERE is_first_draft_bid = true OR is_draft_join = true;

  -- Transfer_History.listing_id FK blocks listing deletes
  DELETE FROM "Transfer_History"
  WHERE listing_id IN (
    SELECT id FROM "Player_Transfer_Listings" WHERE listing_type = 'draft'
  );

  DELETE FROM "Player_Transfer_Listings"
  WHERE listing_type = 'draft';

  UPDATE global_settings
  SET draft_auction_enabled = false,
      draft_random_finish_time = null,
      draft_auction_start_time = null,
      updated_at = now()
  WHERE id = 1;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_reset_draft_auction() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_reset_draft_auction() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reset_draft_auction() TO service_role;
