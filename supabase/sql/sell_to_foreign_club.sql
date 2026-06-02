-- =============================================================================
-- Sell player to foreign club (Squad action)
-- Run once in Supabase SQL Editor (after special_auctions.sql for my_club_shortname).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.sell_player_to_foreign_club(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club           text;
  v_player         public."Players"%rowtype;
  v_fee            numeric;
  v_seller_balance numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = btrim(p_player_id)
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF v_player."Contracted_Team" IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at your club';
  END IF;

  v_fee := greatest(coalesce(v_player.market_value, 0), 0);

  SELECT balance
  INTO v_seller_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_seller_balance IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  -- Close open domestic listings for this player
  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false,
      winning_bid = null,
      winning_club = null
  WHERE btrim(coalesce(l.player_id::text, '')) = btrim(p_player_id)
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Review');

  -- Reject pending direct offers
  UPDATE public."Player_Transfer_Bids" b
  SET status = 'rejected'
  WHERE btrim(coalesce(b.player_id::text, b.direct_bid_id::text, '')) = btrim(p_player_id)
    AND b.is_direct = true
    AND b.listing_id IS NULL
    AND lower(coalesce(b.status, '')) = 'active';

  UPDATE public."Players"
  SET "Contracted_Team" = NULL
  WHERE "Konami_ID"::text = btrim(p_player_id);

  UPDATE public."Club_Finances"
  SET balance = v_seller_balance + v_fee
  WHERE club_name = v_club;

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
    btrim(p_player_id),
    v_club,
    'FOREIGN',
    v_fee,
    0,
    now(),
    NULL
  );

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', btrim(p_player_id),
    'player_name', v_player."Name",
    'seller_club_id', v_club,
    'fee', v_fee,
    'new_balance', v_seller_balance + v_fee
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.sell_player_to_foreign_club(text) TO authenticated;
