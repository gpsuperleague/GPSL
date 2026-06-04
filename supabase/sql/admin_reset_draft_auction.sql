-- =============================================================================
-- Admin: reset draft auction SCHEDULE only (times + disabled flag)
-- Does NOT delete bids, listings, Transfer_History, or change squads/balances.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_reset_draft_auction()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not authorized to reset draft auction';
  END IF;

  UPDATE public.global_settings
  SET draft_auction_enabled = false,
      draft_random_finish_time = null,
      draft_auction_start_time = null,
      updated_at = now()
  WHERE id = 1;
END;
$function$;

-- Emergency only: wipe draft bids/listings/history (old destructive behaviour)
CREATE OR REPLACE FUNCTION public.admin_purge_draft_auction_data()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  DELETE FROM public."Player_Transfer_Bids"
  WHERE listing_id IN (
    SELECT id FROM public."Player_Transfer_Listings" WHERE listing_type = 'draft'
  );

  DELETE FROM public."Player_Transfer_Bids"
  WHERE is_first_draft_bid = true OR is_draft_join = true;

  DELETE FROM public."Transfer_History"
  WHERE listing_id IN (
    SELECT id FROM public."Player_Transfer_Listings" WHERE listing_type = 'draft'
  );

  DELETE FROM public."Player_Transfer_Listings"
  WHERE listing_type = 'draft';

  UPDATE public.global_settings
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

REVOKE ALL ON FUNCTION public.admin_purge_draft_auction_data() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_purge_draft_auction_data() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_purge_draft_auction_data() TO service_role;

NOTIFY pgrst, 'reload schema';
