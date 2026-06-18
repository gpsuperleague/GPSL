-- =============================================================================
-- Admin: remove a manager draft bid and resync listing high bid
-- Run in Supabase SQL Editor.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_remove_manager_draft_bid(p_bid_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_bid public."Manager_Transfer_Bids"%rowtype;
  v_listing_id bigint;
  v_top_amount numeric;
  v_top_bidder text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_bid
  FROM public."Manager_Transfer_Bids"
  WHERE id = p_bid_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Bid % not found', p_bid_id;
  END IF;

  v_listing_id := v_bid.listing_id;

  DELETE FROM public."Manager_Transfer_Bids"
  WHERE id = p_bid_id;

  SELECT b.bid_amount, b.bidder_club_id
  INTO v_top_amount, v_top_bidder
  FROM public."Manager_Transfer_Bids" b
  WHERE b.listing_id = v_listing_id
     OR b.manager_id = v_bid.manager_id
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  IF v_listing_id IS NOT NULL THEN
    UPDATE public."Manager_Transfer_Listings" l
    SET
      current_highest_bid = v_top_amount,
      current_highest_bidder = v_top_bidder,
      updated_at = now()
    WHERE l.id = v_listing_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'deleted_bid_id', p_bid_id,
    'manager_id', v_bid.manager_id,
    'bidder_club_id', v_bid.bidder_club_id,
    'deleted_amount', v_bid.bid_amount,
    'listing_id', v_listing_id,
    'new_highest_bid', v_top_amount,
    'new_highest_bidder', v_top_bidder
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_remove_manager_draft_bid(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- -----------------------------------------------------------------------------
-- Find duplicate Ajax bids on Fran Cudoreni (run first):
--
-- SELECT
--   b.id AS bid_id,
--   m.name,
--   b.bidder_club_id,
--   c.owner AS owner_tag,
--   b.bid_amount,
--   b.bid_time,
--   b.is_first_draft_bid
-- FROM public."Manager_Transfer_Bids" b
-- JOIN public."Managers" m ON m.id = b.manager_id
-- LEFT JOIN public."Clubs" c ON c."ShortName" = b.bidder_club_id
-- WHERE m.slug = 'fran-cudoreni'
--   AND b.bidder_club_id = 'AJX'
-- ORDER BY b.bid_time;
--
-- Remove the duplicate (usually the lower amount or later duplicate first bid):
-- SELECT public.admin_remove_manager_draft_bid(<bid_id_to_drop>);
