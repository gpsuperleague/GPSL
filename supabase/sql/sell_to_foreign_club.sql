-- =============================================================================
-- Sell player to foreign club (Squad action)
-- Run this ENTIRE file in Supabase SQL Editor (after special_auctions.sql).
-- =============================================================================

-- STEP 0 — Per-club quota (max 3 foreign sales)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'Clubs'
      AND column_name = 'foreign_interest_remaining'
  ) THEN
    ALTER TABLE public."Clubs"
      ADD COLUMN foreign_interest_remaining smallint NOT NULL DEFAULT 3
      CHECK (
        foreign_interest_remaining >= 0
        AND foreign_interest_remaining <= 3
      );
  END IF;
END $$;

UPDATE public."Clubs"
SET foreign_interest_remaining = 0
WHERE "ShortName" = 'FOREIGN';

UPDATE public."Clubs"
SET foreign_interest_remaining = 3
WHERE "ShortName" <> 'FOREIGN'
  AND foreign_interest_remaining > 3;

-- STEP 1 — Sentinel buyer for Transfer_History FK
INSERT INTO public."Clubs" ("ShortName", "Club", "Stadium", "Capacity", "Nation")
SELECT 'FOREIGN', 'Foreign club', '—', 0, '—'
WHERE NOT EXISTS (
  SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = 'FOREIGN'
);

UPDATE public."Clubs"
SET foreign_interest_remaining = 0
WHERE "ShortName" = 'FOREIGN';

DROP FUNCTION IF EXISTS public.sell_player_to_foreign_club(text);

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
    RAISE EXCEPTION
      'Clubs row FOREIGN is missing. Run STEP 1 in sell_to_foreign_club.sql.';
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
  v_buyer          text := 'FOREIGN';
  v_interest       int;
  v_interest_after int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  PERFORM public.ensure_foreign_buyer_club();

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT c.foreign_interest_remaining
  INTO v_interest
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club
  FOR UPDATE;

  IF coalesce(v_interest, 0) <= 0 THEN
    RAISE EXCEPTION
      'No foreign clubs are interested in your players (maximum foreign sales reached).';
  END IF;

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

  UPDATE public."Players"
  SET "Contracted_Team" = NULL
  WHERE "Konami_ID"::text = v_pid;

  UPDATE public."Club_Finances"
  SET balance = v_seller_balance + v_fee
  WHERE club_name = v_club;

  UPDATE public."Clubs" c
  SET foreign_interest_remaining = foreign_interest_remaining - 1
  WHERE c."ShortName" = v_club
  RETURNING c.foreign_interest_remaining INTO v_interest_after;

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
    v_buyer,
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
    'buyer_club_id', v_buyer,
    'fee', v_fee,
    'new_balance', v_seller_balance + v_fee,
    'foreign_interest_remaining', v_interest_after
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.player_contracted_club_key(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ensure_foreign_buyer_club() TO authenticated;
GRANT EXECUTE ON FUNCTION public.sell_player_to_foreign_club(text) TO authenticated;

SELECT public.ensure_foreign_buyer_club() AS foreign_buyer_ready;
