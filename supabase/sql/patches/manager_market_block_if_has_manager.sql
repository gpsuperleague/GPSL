-- =============================================================================
-- Manager Transfer Market: block bids if the club already has a manager.
-- Matches draft-auction rules (Managers.contracted_club OR Clubs.manager_id).
-- Enforced in manager_place_bid + BEFORE INSERT on Manager_Transfer_Bids.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_has_signed_manager(p_club_short text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT
    p_club_short IS NOT NULL
    AND btrim(p_club_short) <> ''
    AND (
      EXISTS (
        SELECT 1
        FROM public."Managers" m
        WHERE nullif(btrim(m.contracted_club), '') = p_club_short
      )
      OR EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE c."ShortName" = p_club_short
          AND c.manager_id IS NOT NULL
      )
    );
$function$;

GRANT EXECUTE ON FUNCTION public.club_has_signed_manager(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Bid insert guard: block ANY market/draft bid while club already has a manager
-- ---------------------------------------------------------------------------

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
  IF public.club_has_signed_manager(NEW.bidder_club_id) THEN
    RAISE EXCEPTION
      'Your club already has a manager — sack or transfer them before bidding on another';
  END IF;

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

  PERFORM public.manager_assert_not_sack_blocked(NEW.bidder_club_id, NEW.manager_id);

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

-- ---------------------------------------------------------------------------
-- RPC used by Manager Transfer Market UI
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.manager_place_bid(
  p_listing_id bigint,
  p_amount numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_listing public."Manager_Transfer_Listings"%rowtype;
  v_mgr public."Managers"%rowtype;
  v_balance numeric;
  v_min numeric;
  v_high numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT * INTO v_listing
  FROM public."Manager_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND OR v_listing.status <> 'Active' THEN
    RAISE EXCEPTION 'Listing not open';
  END IF;

  IF v_listing.end_time IS NOT NULL AND v_listing.end_time < now() THEN
    RAISE EXCEPTION 'Listing has expired';
  END IF;

  IF v_listing.seller_club_id IS NOT DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Cannot bid on your own listing';
  END IF;

  IF v_listing.listing_type = 'draft' THEN
    RAISE EXCEPTION 'Use the Manager Draft Auction to bid on draft listings';
  END IF;

  SELECT * INTO v_mgr FROM public."Managers" WHERE id = v_listing.manager_id;

  IF to_regprocedure('public.manager_assert_not_sack_blocked(text, bigint)') IS NOT NULL THEN
    PERFORM public.manager_assert_not_sack_blocked(v_club, v_listing.manager_id);
  END IF;

  IF public.club_has_signed_manager(v_club) THEN
    RAISE EXCEPTION
      'Your club already has a manager — sack or transfer them before bidding on another';
  END IF;

  v_high := coalesce(v_listing.current_highest_bid, 0);
  v_min := greatest(v_listing.market_value::numeric, v_high + 500000);

  IF p_amount < v_min THEN
    RAISE EXCEPTION 'Bid must be at least %', v_min;
  END IF;

  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club;

  IF coalesce(v_balance, 0) < p_amount THEN
    RAISE EXCEPTION 'Insufficient balance';
  END IF;

  INSERT INTO public."Manager_Transfer_Bids" (
    listing_id, manager_id, bidder_club_id, bid_amount, is_direct
  )
  VALUES (p_listing_id, v_listing.manager_id, v_club, p_amount, true);

  UPDATE public."Manager_Transfer_Listings"
  SET current_highest_bid = p_amount,
      current_highest_bidder = v_club,
      updated_at = now()
  WHERE id = p_listing_id;

  RETURN jsonb_build_object('ok', true, 'bid', p_amount, 'listing_id', p_listing_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.manager_place_bid(bigint, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
