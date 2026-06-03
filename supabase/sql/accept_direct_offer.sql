-- Accept a pending direct offer → active transfer listing with opening high bid.
-- Bypasses client RLS. Requires my_club_shortname() (special_auctions.sql).
-- Run once in Supabase SQL Editor AFTER sync_listing_high_from_bid.sql and player_contract_hooks.sql.

CREATE OR REPLACE FUNCTION public.resolve_club_shortname(p_club text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT c."ShortName"
  FROM public."Clubs" c
  WHERE c."ShortName" = btrim(p_club)
     OR c."Club" = btrim(p_club)
  LIMIT 1;
$$;

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

GRANT EXECUTE ON FUNCTION public.resolve_club_shortname(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_direct_offer(bigint, timestamptz) TO authenticated;

NOTIFY pgrst, 'reload schema';
