-- =============================================================================
-- Manager draft auction — bids, guard, settlement (parallel to player draft)
-- Run after managers_system.sql. Updates transferengine_settle_draft_auctions.
-- =============================================================================

ALTER TABLE public."Manager_Transfer_Bids"
  ADD COLUMN IF NOT EXISTS is_first_draft_bid boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS is_draft_join boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS draft_join_consumed boolean NOT NULL DEFAULT false;

-- Reject manager draft bids after secret finish (manager draft enabled)
CREATE OR REPLACE FUNCTION public.trg_manager_transfer_bids_draft_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_enabled boolean;
  v_start   timestamptz;
  v_finish  timestamptz;
  v_is_draft boolean;
  v_other_mid bigint;
BEGIN
  v_is_draft := (
    COALESCE(NEW.is_first_draft_bid, false)
    OR COALESCE(NEW.is_draft_join, false)
    OR (
      NEW.listing_id IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM public."Manager_Transfer_Listings" l
        WHERE l.id = NEW.listing_id AND l.listing_type = 'draft'
      )
    )
  );

  IF NOT v_is_draft THEN
    RETURN NEW;
  END IF;

  SELECT manager_draft_auction_enabled, draft_auction_start_time, draft_random_finish_time
  INTO v_enabled, v_start, v_finish
  FROM public.global_settings
  WHERE id = 1;

  IF NOT COALESCE(v_enabled, false) THEN
    RAISE EXCEPTION 'Manager draft auction is not enabled';
  END IF;

  IF v_start IS NOT NULL AND now() < v_start THEN
    RAISE EXCEPTION 'Manager draft auction has not started yet';
  END IF;

  IF v_start IS NOT NULL AND v_finish IS NULL THEN
    v_finish := v_start + interval '23 hours 59 minutes 59 seconds';
  END IF;

  IF v_finish IS NOT NULL AND now() >= v_finish THEN
    RAISE EXCEPTION 'Manager draft bidding has closed';
  END IF;

  -- One leading bid per club across active manager draft listings
  SELECT l.manager_id INTO v_other_mid
  FROM public."Manager_Transfer_Listings" l
  WHERE l.listing_type = 'draft'
    AND l.status = 'Active'
    AND l.manager_id <> NEW.manager_id
    AND l.current_highest_bidder = NEW.bidder_club_id
  LIMIT 1;

  IF v_other_mid IS NOT NULL THEN
    RAISE EXCEPTION 'You may only hold the highest bid on one manager draft auction at a time';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS manager_transfer_bids_draft_guard ON public."Manager_Transfer_Bids";
CREATE TRIGGER manager_transfer_bids_draft_guard
  BEFORE INSERT ON public."Manager_Transfer_Bids"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_manager_transfer_bids_draft_guard();

DROP POLICY IF EXISTS manager_bids_insert ON public."Manager_Transfer_Bids";
CREATE POLICY manager_bids_insert ON public."Manager_Transfer_Bids"
  FOR INSERT TO authenticated
  WITH CHECK (bidder_club_id = public.my_club_shortname());

DROP POLICY IF EXISTS manager_listings_insert ON public."Manager_Transfer_Listings";
CREATE POLICY manager_listings_insert ON public."Manager_Transfer_Listings"
  FOR INSERT TO authenticated
  WITH CHECK (listing_type = 'draft' AND seller_club_id IS NULL);

DROP POLICY IF EXISTS manager_listings_update ON public."Manager_Transfer_Listings";
CREATE POLICY manager_listings_update ON public."Manager_Transfer_Listings"
  FOR UPDATE TO authenticated
  USING (listing_type = 'draft' OR seller_club_id = public.my_club_shortname())
  WITH CHECK (true);

-- Settle one manager draft listing (mirror player draft)
CREATE OR REPLACE FUNCTION public.transferengine_accept_manager_draft_sale(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Manager_Transfer_Listings"%rowtype;
  v_amount  numeric;
  v_buyer   text;
  v_mgr     public."Managers"%rowtype;
BEGIN
  SELECT * INTO v_listing
  FROM public."Manager_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND OR v_listing.listing_type IS DISTINCT FROM 'draft' THEN
    RETURN;
  END IF;

  IF v_listing.status NOT IN ('Active', 'Review') THEN
    RETURN;
  END IF;

  SELECT b.bid_amount, b.bidder_club_id
  INTO v_amount, v_buyer
  FROM public."Manager_Transfer_Bids" b
  WHERE b.listing_id = v_listing.id
     OR b.manager_id = v_listing.manager_id
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  IF v_buyer IS NULL OR v_amount IS NULL THEN
    UPDATE public."Manager_Transfer_Listings"
    SET status = 'Closed', transfer_completed = false, updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  SELECT * INTO v_mgr FROM public."Managers" WHERE id = v_listing.manager_id FOR UPDATE;

  IF NOT FOUND OR v_mgr.contracted_club IS NOT NULL AND btrim(v_mgr.contracted_club) <> '' THEN
    UPDATE public."Manager_Transfer_Listings"
    SET status = 'Closed', transfer_completed = false, updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  UPDATE public."Manager_Transfer_Listings"
  SET current_highest_bid = v_amount,
      current_highest_bidder = v_buyer,
      updated_at = now()
  WHERE id = v_listing.id;

  BEGIN
    PERFORM public.manager_assign_to_club(v_listing.manager_id, v_buyer, 2, v_amount, true);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Manager draft listing % assign failed: %', p_listing_id, SQLERRM;
    RETURN;
  END;

  UPDATE public."Manager_Transfer_Listings"
  SET status = 'Closed', transfer_completed = true, updated_at = now()
  WHERE id = v_listing.id;
END;
$function$;

-- Settlement: re-apply transferengine_draft.sql (includes player + manager loops).
-- This patch only adds bid guard + accept_manager_draft_sale above if missing.

GRANT EXECUTE ON FUNCTION public.transferengine_accept_manager_draft_sale(bigint) TO authenticated;
