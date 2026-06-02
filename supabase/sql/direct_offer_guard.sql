-- One pending direct offer per player (contracted) — blocks duplicate inserts server-side
-- Run once in Supabase SQL Editor after transfer engine scripts.

CREATE OR REPLACE FUNCTION public.trg_player_transfer_bids_direct_offer_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT COALESCE(NEW.is_direct, false) THEN
    RETURN NEW;
  END IF;

  IF NEW.listing_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.direct_bid_id IS NULL OR btrim(NEW.direct_bid_id::text) = '' THEN
    RAISE EXCEPTION 'Direct offer must include player id (direct_bid_id)';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM "Player_Transfer_Bids" b
    WHERE b.direct_bid_id::text = NEW.direct_bid_id::text
      AND b.is_direct = true
      AND b.listing_id IS NULL
      AND lower(coalesce(b.status, '')) = 'active'
      AND (TG_OP = 'INSERT' OR b.bid_id IS DISTINCT FROM NEW.bid_id)
  ) THEN
    RAISE EXCEPTION 'An offer is already under review for this player';
  END IF;

  IF NEW.status IS NULL OR btrim(NEW.status) = '' THEN
    NEW.status := 'active';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_bids_direct_offer_guard ON "Player_Transfer_Bids";

CREATE TRIGGER player_transfer_bids_direct_offer_guard
  BEFORE INSERT ON "Player_Transfer_Bids"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_player_transfer_bids_direct_offer_guard();
