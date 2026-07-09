-- =============================================================================
-- Block clubs buying their own transfer listings
--
-- Confirmed: listings 1665/1666 closed with seller=bidder=winning_club=AND.
-- UI already blocks self-bids; server did not. Settlement also allowed buyer=seller.
--
-- This patch:
--   1) Rejects bid INSERT/UPDATE when bidder = listing seller
--   2) Rejects listing UPDATE that sets current_highest_bidder = seller
--   3) Ignores seller bids when syncing high bid
--   4) Refuses accept_sale when buyer = seller
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Bid guard
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.trg_player_transfer_bids_block_own_listing()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_seller text;
  v_bidder text := upper(btrim(coalesce(NEW.bidder_club_id::text, '')));
BEGIN
  IF v_bidder = '' THEN
    RETURN NEW;
  END IF;

  IF NEW.listing_id IS NOT NULL THEN
    SELECT upper(btrim(l.seller_club_id::text))
    INTO v_seller
    FROM public."Player_Transfer_Listings" l
    WHERE l.id = NEW.listing_id;
  END IF;

  IF v_seller IS NULL OR v_seller = '' THEN
    v_seller := upper(btrim(coalesce(NEW.seller_club_id::text, '')));
  END IF;

  IF v_seller IS NOT NULL AND v_seller <> '' AND v_seller = v_bidder THEN
    RAISE EXCEPTION 'Cannot bid on your own listing';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_bids_block_own_listing ON public."Player_Transfer_Bids";
CREATE TRIGGER player_transfer_bids_block_own_listing
  BEFORE INSERT OR UPDATE OF bidder_club_id, listing_id, seller_club_id
  ON public."Player_Transfer_Bids"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_player_transfer_bids_block_own_listing();

-- ---------------------------------------------------------------------------
-- 2) Listing high-bidder guard (client also writes current_highest_* after bid)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.trg_player_transfer_listings_block_own_high_bid()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_seller text := upper(btrim(coalesce(NEW.seller_club_id::text, '')));
  v_bidder text := upper(btrim(coalesce(NEW.current_highest_bidder::text, '')));
  v_winner text := upper(btrim(coalesce(NEW.winning_club::text, '')));
BEGIN
  IF v_seller = '' THEN
    RETURN NEW;
  END IF;

  IF v_bidder <> '' AND v_bidder = v_seller THEN
    -- Clear self high-bid rather than aborting unrelated listing updates
    NEW.current_highest_bidder := NULL;
    NEW.current_highest_bid := NULL;
  END IF;

  IF TG_OP = 'UPDATE'
     AND NEW.status IN ('Active', 'Review', 'Seller Review')
     AND v_winner <> ''
     AND v_winner = v_seller
     AND coalesce(NEW.transfer_completed, false) IS NOT TRUE THEN
    NEW.winning_club := NULL;
    NEW.winning_bid := NULL;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_listings_block_own_high_bid
  ON public."Player_Transfer_Listings";
CREATE TRIGGER player_transfer_listings_block_own_high_bid
  BEFORE INSERT OR UPDATE OF current_highest_bidder, current_highest_bid,
    winning_club, winning_bid, seller_club_id, status
  ON public."Player_Transfer_Listings"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_player_transfer_listings_block_own_high_bid();

-- ---------------------------------------------------------------------------
-- 3) Sync high bid — ignore seller / self bids
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.transferengine_sync_listing_high_bid(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Player_Transfer_Listings"%rowtype;
  v_amount  numeric;
  v_buyer   text;
  v_seller  text;
BEGIN
  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_seller := upper(btrim(coalesce(v_listing.seller_club_id::text, '')));

  SELECT b.bid_amount, b.bidder_club_id::text
  INTO v_amount, v_buyer
  FROM public."Player_Transfer_Bids" b
  WHERE b.listing_id = p_listing_id
    AND upper(btrim(coalesce(b.bidder_club_id::text, ''))) IS DISTINCT FROM v_seller
    AND lower(coalesce(b.status::text, '')) NOT IN ('rejected', 'cancelled')
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  IF v_buyer IS NULL THEN
    SELECT b.bid_amount, b.bidder_club_id::text
    INTO v_amount, v_buyer
    FROM public."Player_Transfer_Bids" b
    WHERE btrim(coalesce(b.player_id, b.direct_bid_id::text, '')) = btrim(v_listing.player_id::text)
      AND upper(btrim(coalesce(b.bidder_club_id::text, ''))) IS DISTINCT FROM v_seller
      AND lower(coalesce(b.status::text, '')) NOT IN ('rejected', 'cancelled')
    ORDER BY b.bid_amount DESC, b.bid_time ASC
    LIMIT 1;
  END IF;

  IF v_buyer IS NULL OR v_amount IS NULL THEN
    -- No external bid — clear any stale self high-bid
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
      OR (v_amount = current_highest_bid AND current_highest_bidder IS DISTINCT FROM v_buyer)
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
      OR (
        NEW.bid_amount = l.current_highest_bid
        AND l.current_highest_bidder IS DISTINCT FROM NEW.bidder_club_id
      )
      OR upper(btrim(coalesce(l.current_highest_bidder::text, '')))
           = upper(btrim(coalesce(l.seller_club_id::text, '')))
    );

  RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4) accept_sale — refuse buyer = seller
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.transferengine_accept_sale(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing          public."Player_Transfer_Listings"%rowtype;
  v_player           public."Players"%rowtype;
  v_history_id       bigint;
  v_fee              numeric;
  v_buyer            text;
  v_seller           text;
  v_allow_same_season boolean := false;
BEGIN
  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Listing % not found', p_listing_id;
    RETURN;
  END IF;

  IF v_listing.status NOT IN ('Active', 'Review') THEN
    RAISE NOTICE 'Listing % already processed', p_listing_id;
    RETURN;
  END IF;

  -- Prefer an external high bid (ignore seller self-bids)
  PERFORM public.transferengine_sync_listing_high_bid(p_listing_id);

  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id;

  v_fee := v_listing.current_highest_bid;
  v_buyer := upper(btrim(coalesce(v_listing.current_highest_bidder::text, '')));
  v_seller := upper(btrim(coalesce(v_listing.seller_club_id::text, '')));

  IF v_buyer = '' OR v_fee IS NULL THEN
    RAISE NOTICE 'No winning bid for listing %', p_listing_id;
    RETURN;
  END IF;

  IF v_buyer = v_seller THEN
    RAISE NOTICE 'Buyer equals seller for listing % — sale blocked', p_listing_id;
    RETURN;
  END IF;

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_listing.player_id::text
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Player not found for listing %', p_listing_id;
    RETURN;
  END IF;

  IF v_player."Contracted_Team" IS DISTINCT FROM v_listing.seller_club_id
     AND upper(btrim(coalesce(v_player."Contracted_Team", ''))) IS DISTINCT FROM v_seller THEN
    IF upper(btrim(coalesce(v_player."Contracted_Team", ''))) = v_buyer
       AND EXISTS (
         SELECT 1
         FROM public."Transfer_History" h
         WHERE h.listing_id = v_listing.id
       ) THEN
      UPDATE public."Player_Transfer_Listings"
      SET status = 'Closed',
          transfer_completed = true,
          winning_bid = coalesce(v_fee, v_listing.winning_bid),
          winning_club = coalesce(v_listing.current_highest_bidder, v_listing.winning_club)
      WHERE id = v_listing.id
        AND status IN ('Active', 'Review');
      RAISE NOTICE 'Listing % already transferred — closed listing only', p_listing_id;
      RETURN;
    END IF;

    RAISE NOTICE 'Player no longer at selling club for listing %', p_listing_id;
    RETURN;
  END IF;

  v_allow_same_season :=
    coalesce(v_listing.new_owner_slot, false)
    OR coalesce(v_listing.perpetual_renew, false)
    OR coalesce(v_listing.special_rules ->> 'new_owner_list', '') = 'true'
    OR coalesce(v_listing.special_rules ->> 'source', '') = 'underperformance';

  IF NOT v_allow_same_season
     AND public.player_signed_this_season(v_player."Season_Signed") THEN
    RAISE NOTICE 'Player signed this season — sale blocked for listing %', p_listing_id;
    RETURN;
  END IF;

  PERFORM public.player_assign_to_club(
    v_listing.player_id::text,
    v_listing.current_highest_bidder,
    NULL::numeric,
    false
  );

  INSERT INTO public."Transfer_History" (
    player_id,
    seller_club_id,
    buyer_club_id,
    fee,
    agent_fee,
    transfer_time,
    listing_id
  )
  VALUES (
    v_listing.player_id,
    v_listing.seller_club_id,
    v_listing.current_highest_bidder,
    v_fee,
    0,
    now(),
    v_listing.id
  )
  RETURNING id INTO v_history_id;

  IF to_regprocedure('public.post_transfer_ledger_for_history(bigint)') IS NOT NULL THEN
    PERFORM public.post_transfer_ledger_for_history(v_history_id);
  ELSIF to_regprocedure('public.post_transfer_ledger_for_history(bigint, boolean)') IS NOT NULL THEN
    PERFORM public.post_transfer_ledger_for_history(v_history_id, true);
  ELSE
    UPDATE public."Club_Finances"
    SET balance = balance - v_fee
    WHERE club_name = v_listing.current_highest_bidder;
    UPDATE public."Club_Finances"
    SET balance = balance + v_fee
    WHERE club_name = v_listing.seller_club_id;
  END IF;

  UPDATE public."Player_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = true,
      winning_bid = v_fee,
      winning_club = v_listing.current_highest_bidder
  WHERE id = v_listing.id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 5) Expiry: after accept fails, if only self-bid remains → close unsold
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.transferengine_evaluate_expired_listing(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Player_Transfer_Listings"%rowtype;
  v_now timestamptz := now();
  v_status text;
  v_seller text;
  v_buyer text;
BEGIN
  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Listing % not found in evaluate_expired_listing', p_listing_id;
    RETURN;
  END IF;

  PERFORM public.transferengine_sync_listing_high_bid(p_listing_id);

  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id;

  IF v_listing.current_highest_bid IS NULL
     OR v_listing.current_highest_bidder IS NULL THEN
    IF coalesce(v_listing.perpetual_renew, false)
       AND to_regprocedure('public.transferengine_perpetual_relist(bigint)') IS NOT NULL THEN
      PERFORM public.transferengine_perpetual_relist(p_listing_id);
    ELSE
      UPDATE public."Player_Transfer_Listings"
      SET status = 'Closed',
          transfer_completed = false
      WHERE id = v_listing.id;
    END IF;
    RETURN;
  END IF;

  v_seller := upper(btrim(coalesce(v_listing.seller_club_id::text, '')));
  v_buyer := upper(btrim(coalesce(v_listing.current_highest_bidder::text, '')));

  IF v_buyer = v_seller THEN
    UPDATE public."Player_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = false,
        current_highest_bid = NULL,
        current_highest_bidder = NULL
    WHERE id = v_listing.id;
    RAISE NOTICE 'Listing % had only seller self-bid — closed unsold', v_listing.id;
    RETURN;
  END IF;

  IF v_listing.current_highest_bid >= v_listing.reserve_price THEN
    PERFORM public.transferengine_accept_sale(v_listing.id);

    SELECT status INTO v_status
    FROM public."Player_Transfer_Listings"
    WHERE id = v_listing.id;

    IF v_status = 'Active' THEN
      UPDATE public."Player_Transfer_Listings"
      SET status = 'Review',
          seller_review_deadline = v_now + interval '24 hours'
      WHERE id = v_listing.id
        AND status = 'Active';
      RAISE NOTICE
        'Listing % accept_sale did not complete — moved to Review',
        v_listing.id;
    END IF;
    RETURN;
  END IF;

  UPDATE public."Player_Transfer_Listings"
  SET status = 'Review',
      seller_review_deadline = v_now + interval '24 hours'
  WHERE id = v_listing.id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transferengine_accept_sale(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_sync_listing_high_bid(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_evaluate_expired_listing(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Optional forensics for 1665/1666:
-- SELECT * FROM "Player_Transfer_Bids" WHERE listing_id IN (1665, 1666);
