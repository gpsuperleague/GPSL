-- One pending direct offer per player (contracted) — blocks duplicate inserts server-side
-- Superseded by player_transfer_bids_player_id.sql (player_id column + guard).
-- Run player_transfer_bids_player_id.sql instead of this file alone.

CREATE OR REPLACE FUNCTION public.trg_player_transfer_bids_direct_offer_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player_id text;
BEGIN
  IF NOT COALESCE(NEW.is_direct, false) THEN
    RETURN NEW;
  END IF;

  IF NEW.listing_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  v_player_id := btrim(coalesce(NEW.player_id, NEW.direct_bid_id::text, ''));

  IF v_player_id = '' THEN
    RAISE EXCEPTION 'Direct offer must include player id (player_id)';
  END IF;

  IF NEW.player_id IS NULL OR btrim(NEW.player_id) = '' THEN
    NEW.player_id := v_player_id;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM "Player_Transfer_Bids" b
    WHERE btrim(coalesce(b.player_id, b.direct_bid_id::text, '')) = v_player_id
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
