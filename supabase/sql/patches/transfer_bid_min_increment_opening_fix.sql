-- =============================================================================
-- Fix: accept_direct_offer blocked by "Bid must be at least X" (+₿500k)
--
-- Cause: accept_direct_offer inserts the listing with current_highest_bid already
-- set to the offer, then inserts the opening bid at the same amount. The min-
-- increment trigger treated listing high as an existing bid and required +₿500k.
--
-- Fix: the +₿500k raise only applies when there is already at least one
-- competing bid *row* on the listing. Opening bids (incl. direct-offer accept)
-- only need ≥ market value.
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.trg_player_transfer_bids_min_increment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Player_Transfer_Listings"%rowtype;
  v_high numeric;
  v_live_high numeric;
  v_mv numeric;
  v_min numeric;
BEGIN
  -- Pure direct offers (no listing) use their own rules
  IF NEW.listing_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- accept_direct_offer / similar SECURITY DEFINER paths may seed the listing high
  -- then insert the matching opening bid as the seller acting for the buyer
  IF current_setting('gpsl.bypass_bid_owner_check', true) = 'on' THEN
    RETURN NEW;
  END IF;

  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = NEW.listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Listing not found';
  END IF;

  v_mv := coalesce(v_listing.market_value::numeric, 0);

  -- Live max from existing bid rows only (listing high may be pre-seeded)
  SELECT coalesce(max(b.bid_amount), 0)
  INTO v_live_high
  FROM public."Player_Transfer_Bids" b
  WHERE b.listing_id = NEW.listing_id
    AND upper(btrim(coalesce(b.bidder_club_id::text, '')))
        IS DISTINCT FROM upper(btrim(coalesce(v_listing.seller_club_id::text, '')));

  IF v_live_high IS NULL OR v_live_high <= 0 THEN
    -- Opening bid on this listing — market value floor only
    v_min := v_mv;
  ELSE
    -- Later bids: ≥ max(market value, current high + ₿500k)
    -- Prefer the greater of listing high and live max (listing can be stale)
    v_high := greatest(
      coalesce(v_listing.current_highest_bid::numeric, 0),
      v_live_high
    );
    v_min := greatest(v_mv, v_high + 500000);
  END IF;

  IF NEW.bid_amount IS NULL OR NEW.bid_amount < v_min THEN
    RAISE EXCEPTION 'Bid must be at least %', v_min;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_bids_min_increment ON public."Player_Transfer_Bids";

CREATE TRIGGER player_transfer_bids_min_increment
  BEFORE INSERT ON public."Player_Transfer_Bids"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_player_transfer_bids_min_increment();
