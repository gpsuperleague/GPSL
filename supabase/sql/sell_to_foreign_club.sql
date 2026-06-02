-- =============================================================================
-- Sell player to foreign club (Squad action)
-- Run once in Supabase SQL Editor (after special_auctions.sql for my_club_shortname).
--
-- Players table: free agent = Contracted_Team IS NULL (not 'FOREIGN').
-- Transfer_History: buyer_club_id = 'FOREIGN' (sentinel Clubs row; column NOT NULL + FK).
-- =============================================================================

-- NULL or blank → free agent; otherwise trimmed ShortName
CREATE OR REPLACE FUNCTION public.player_contracted_club_key(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_value IS NULL THEN NULL
    WHEN btrim(p_value) = '' THEN NULL
    ELSE btrim(p_value)
  END;
$$;

-- Sentinel row for transfer history only (not a playable club)
CREATE OR REPLACE FUNCTION public.ensure_foreign_buyer_club()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = 'FOREIGN'
  ) THEN
    INSERT INTO public."Clubs" ("ShortName", "Club", "Stadium", "Capacity", "Nation")
    VALUES ('FOREIGN', 'Foreign club', '—', 0, '—');
  END IF;

  RETURN 'FOREIGN';
END;
$function$;

CREATE OR REPLACE FUNCTION public.sell_player_to_foreign_club(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club           text;
  v_player         public."Players"%rowtype;
  v_pid            text;
  v_fee            numeric;
  v_seller_balance numeric;
  v_foreign        text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  v_foreign := public.ensure_foreign_buyer_club();
  v_pid := btrim(p_player_id);

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at your club';
  END IF;

  v_fee := greatest(coalesce(v_player.market_value::numeric, 0::numeric), 0::numeric);

  SELECT balance
  INTO v_seller_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_seller_balance IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false,
      winning_bid = null,
      winning_club = null
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Review');

  UPDATE public."Player_Transfer_Bids" b
  SET status = 'rejected'
  WHERE b.is_direct = true
    AND b.listing_id IS NULL
    AND lower(coalesce(b.status::text, '')) = 'active'
    AND (
      (b.player_id IS NOT NULL AND btrim(b.player_id::text) = v_pid)
      OR (b.direct_bid_id IS NOT NULL AND btrim(b.direct_bid_id::text) = v_pid)
    );

  -- Free agent in GPSL = NULL (GPDB / draft use Contracted_Team.is.null)
  UPDATE public."Players"
  SET "Contracted_Team" = NULL
  WHERE "Konami_ID"::text = v_pid;

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
    v_player."Konami_ID",
    v_club,
    v_foreign,
    v_fee,
    0,
    now(),
    NULL
  );

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_player."Konami_ID",
    'player_name', v_player."Name",
    'seller_club_id', v_club,
    'buyer_club_id', v_foreign,
    'contracted_team', null,
    'fee', v_fee,
    'new_balance', v_seller_balance + v_fee
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.player_contracted_club_key(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ensure_foreign_buyer_club() TO authenticated;
GRANT EXECUTE ON FUNCTION public.sell_player_to_foreign_club(text) TO authenticated;
