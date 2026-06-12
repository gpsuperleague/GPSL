-- Block manager draft bids while the bidder's club already has a manager signed.
-- Run after managers_draft_auction.sql.

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

  IF EXISTS (
    SELECT 1
    FROM public."Managers" m
    WHERE m.contracted_club = NEW.bidder_club_id
  ) OR EXISTS (
    SELECT 1
    FROM public."Clubs" c
    WHERE c."ShortName" = NEW.bidder_club_id
      AND c.manager_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION
      'Your club already has a manager — sack them before bidding in the manager draft auction';
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
