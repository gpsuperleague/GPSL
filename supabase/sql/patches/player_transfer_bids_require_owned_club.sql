-- =============================================================================
-- Require an owned GPSL club to place player bids/offers or start draft listings.
-- Waiting-list members (no Clubs.owner_id) must not bid via GPDB / market.
-- Safe re-run.
--
-- Bypass (transaction-local) for SECURITY DEFINER paths that insert a bid on
-- behalf of another club (e.g. accept_direct_offer copies buyer bid onto listing):
--   PERFORM set_config('gpsl.bypass_bid_owner_check', 'on', true);
-- =============================================================================

CREATE OR REPLACE FUNCTION public.trg_player_transfer_bids_require_owned_club()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_mine text;
BEGIN
  IF current_setting('gpsl.bypass_bid_owner_check', true) = 'on' THEN
    RETURN NEW;
  END IF;

  -- SQL Editor / service_role jobs have no JWT
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF public.is_gpsl_admin() THEN
    RETURN NEW;
  END IF;

  v_mine := nullif(btrim(coalesce(public.my_club_shortname(), '')), '');
  IF v_mine IS NULL THEN
    RAISE EXCEPTION
      'You must own a club to place bids or offers (waiting-list members cannot bid)';
  END IF;

  IF upper(btrim(coalesce(NEW.bidder_club_id::text, '')))
       IS DISTINCT FROM upper(btrim(v_mine)) THEN
    RAISE EXCEPTION 'bidder_club_id must be your own club';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_bids_00_require_owned_club
  ON public."Player_Transfer_Bids";
CREATE TRIGGER player_transfer_bids_00_require_owned_club
  BEFORE INSERT ON public."Player_Transfer_Bids"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_player_transfer_bids_require_owned_club();

-- Draft threads / listings: no club → cannot open a listing either
CREATE OR REPLACE FUNCTION public.trg_player_transfer_listings_require_owned_club()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF current_setting('gpsl.bypass_bid_owner_check', true) = 'on' THEN
    RETURN NEW;
  END IF;

  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF public.is_gpsl_admin() THEN
    RETURN NEW;
  END IF;

  IF nullif(btrim(coalesce(public.my_club_shortname(), '')), '') IS NULL THEN
    RAISE EXCEPTION
      'You must own a club to list players or start draft auctions';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_listings_00_require_owned_club
  ON public."Player_Transfer_Listings";
CREATE TRIGGER player_transfer_listings_00_require_owned_club
  BEFORE INSERT ON public."Player_Transfer_Listings"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_player_transfer_listings_require_owned_club();

-- accept_direct_offer inserts a listing + bid as the seller, with buyer as bidder
CREATE OR REPLACE FUNCTION public.accept_direct_offer(
  p_bid_id bigint,
  p_end_time timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club           text;
  v_bid            public."Player_Transfer_Bids"%rowtype;
  v_seller_short   text;
  v_player_id      text;
  v_listing_id     bigint;
  v_market_value   numeric;
  v_now            timestamptz := now();
  v_end            timestamptz;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT *
  INTO v_bid
  FROM public."Player_Transfer_Bids"
  WHERE bid_id = p_bid_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Direct offer not found';
  END IF;

  IF NOT COALESCE(v_bid.is_direct, false) THEN
    RAISE EXCEPTION 'Not a direct offer';
  END IF;

  IF v_bid.listing_id IS NOT NULL THEN
    RAISE EXCEPTION 'Direct offer already converted to a listing';
  END IF;

  IF lower(coalesce(v_bid.status::text, '')) <> 'active' THEN
    RAISE EXCEPTION 'Direct offer is not active';
  END IF;

  v_seller_short := public.resolve_club_shortname(v_bid.seller_club_id);
  IF v_seller_short IS NULL OR v_seller_short IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'This offer is not for your club';
  END IF;

  v_player_id := btrim(coalesce(v_bid.player_id, v_bid.direct_bid_id::text, ''));
  IF v_player_id = '' THEN
    RAISE EXCEPTION 'Direct offer missing player id';
  END IF;

  PERFORM public.assert_player_transferable(v_player_id);

  v_end := coalesce(p_end_time, v_now + interval '24 hours');

  SELECT p.market_value
  INTO v_market_value
  FROM public."Players" p
  WHERE btrim(p."Konami_ID"::text) = v_player_id
  LIMIT 1;

  v_market_value := coalesce(v_market_value, v_bid.bid_amount);

  -- Seller inserts buyer bid onto new listing — not the caller's club as bidder
  PERFORM set_config('gpsl.bypass_bid_owner_check', 'on', true);

  INSERT INTO public."Player_Transfer_Listings" (
    player_id,
    seller_club_id,
    reserve_price,
    market_value,
    status,
    listing_type,
    created_at,
    start_time,
    end_time,
    initial_end_time,
    current_highest_bid,
    current_highest_bidder
  )
  VALUES (
    v_player_id,
    v_club,
    v_bid.bid_amount,
    v_market_value,
    'Active',
    'direct',
    v_now,
    v_now,
    v_end,
    v_end,
    v_bid.bid_amount,
    v_bid.bidder_club_id
  )
  RETURNING id INTO v_listing_id;

  INSERT INTO public."Player_Transfer_Bids" (
    listing_id,
    player_id,
    direct_bid_id,
    bidder_club_id,
    seller_club_id,
    bid_amount,
    bid_time,
    is_direct,
    status
  )
  VALUES (
    v_listing_id,
    v_player_id,
    NULL,
    v_bid.bidder_club_id,
    v_club,
    v_bid.bid_amount,
    v_now,
    false,
    'active'
  );

  UPDATE public."Player_Transfer_Bids"
  SET
    status = 'accepted',
    listing_id = v_listing_id,
    seller_club_id = v_club
  WHERE bid_id = p_bid_id;

  RETURN jsonb_build_object(
    'listing_id', v_listing_id,
    'player_id', v_player_id,
    'current_highest_bid', v_bid.bid_amount,
    'current_highest_bidder', v_bid.bidder_club_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.accept_direct_offer(bigint, timestamptz) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Optional: find active bids from accounts that do not own the bidder club
-- (run manually after deploy if you need to clean up bad offers)
-- SELECT b.bid_id, b.bidder_club_id, b.player_id, b.bid_amount, b.status, b.is_direct, b.bid_time
-- FROM public."Player_Transfer_Bids" b
-- WHERE lower(coalesce(b.status, '')) = 'active'
--   AND NOT EXISTS (
--     SELECT 1 FROM public."Clubs" c
--     WHERE upper(btrim(c."ShortName")) = upper(btrim(b.bidder_club_id))
--       AND c.owner_id IS NOT NULL
--   );
