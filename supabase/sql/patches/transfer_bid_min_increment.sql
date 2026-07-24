-- =============================================================================
-- Player transfer / draft bids — enforce ₿500,000 minimum raise
--
-- Bug: UI required high + ₿500k, but the DB accepted equal bids. The listing
-- sync trigger even promoted a matching bid from another club to high bidder.
--
-- This patch:
--   1) BEFORE INSERT: reject auction bids below market value / high + ₿500k
--      (skips pure direct offers with no listing_id)
--   2) Sync high-bid only when strictly greater (no equal-bid takeover)
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
  v_mv numeric;
  v_min numeric;
BEGIN
  -- Pure direct offers (no listing) use their own rules
  IF NEW.listing_id IS NULL THEN
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

  -- accept_direct_offer seeds listing.current_highest_bid before inserting the
  -- opening bid at the same amount — do not treat listing high alone as a prior bid.
  -- +₿500k only applies when competing bid rows already exist.
  IF current_setting('gpsl.bypass_bid_owner_check', true) = 'on' THEN
    RETURN NEW;
  END IF;

  SELECT coalesce(max(b.bid_amount), 0)
  INTO v_high
  FROM public."Player_Transfer_Bids" b
  WHERE b.listing_id = NEW.listing_id
    AND upper(btrim(coalesce(b.bidder_club_id::text, '')))
        IS DISTINCT FROM upper(btrim(coalesce(v_listing.seller_club_id::text, '')));

  IF v_high IS NULL OR v_high <= 0 THEN
    v_min := v_mv;
  ELSE
    v_high := greatest(
      coalesce(v_listing.current_highest_bid::numeric, 0),
      v_high
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

-- ---------------------------------------------------------------------------
-- Sync listing high — only strict raises (no equal-amount takeover)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.transferengine_sync_listing_high_bid(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Player_Transfer_Listings"%rowtype;
  v_seller text;
  v_buyer text;
  v_amount numeric;
BEGIN
  SELECT * INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_seller := upper(btrim(coalesce(v_listing.seller_club_id::text, '')));

  SELECT b.bidder_club_id, b.bid_amount
  INTO v_buyer, v_amount
  FROM public."Player_Transfer_Bids" b
  WHERE b.listing_id = p_listing_id
    AND upper(btrim(coalesce(b.bidder_club_id::text, ''))) IS DISTINCT FROM v_seller
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  IF v_buyer IS NULL OR v_amount IS NULL THEN
    IF upper(btrim(coalesce(v_listing.current_highest_bidder::text, ''))) = v_seller THEN
      UPDATE public."Player_Transfer_Listings"
      SET current_highest_bid = NULL,
          current_highest_bidder = NULL
      WHERE id = p_listing_id;
    END IF;
    RETURN;
  END IF;

  UPDATE public."Player_Transfer_Listings"
  SET current_highest_bid = v_amount,
      current_highest_bidder = v_buyer
  WHERE id = p_listing_id
    AND (
      current_highest_bid IS NULL
      OR v_amount > current_highest_bid
      OR upper(btrim(coalesce(current_highest_bidder::text, ''))) = v_seller
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_sync_listing_high_from_bid()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_seller text;
BEGIN
  IF NEW.listing_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.bidder_club_id IS NULL OR btrim(NEW.bidder_club_id::text) = '' THEN
    RETURN NEW;
  END IF;

  SELECT upper(btrim(l.seller_club_id::text))
  INTO v_seller
  FROM public."Player_Transfer_Listings" l
  WHERE l.id = NEW.listing_id;

  IF v_seller IS NOT NULL
     AND upper(btrim(NEW.bidder_club_id::text)) = v_seller THEN
    RETURN NEW;
  END IF;

  UPDATE public."Player_Transfer_Listings" l
  SET
    current_highest_bid = NEW.bid_amount,
    current_highest_bidder = NEW.bidder_club_id
  WHERE l.id = NEW.listing_id
    AND (
      l.current_highest_bid IS NULL
      OR NEW.bid_amount > l.current_highest_bid
      OR upper(btrim(coalesce(l.current_highest_bidder::text, '')))
           = upper(btrim(coalesce(l.seller_club_id::text, '')))
    );

  RETURN NEW;
END;
$function$;
