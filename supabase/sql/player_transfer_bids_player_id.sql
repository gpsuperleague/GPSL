-- =============================================================================
-- Player_Transfer_Bids.player_id — canonical Konami ID on every bid row
-- Run once in Supabase SQL Editor after direct_offer_guard.sql
-- =============================================================================

ALTER TABLE public."Player_Transfer_Bids"
  ADD COLUMN IF NOT EXISTS player_id text;

-- Legacy: direct_bid_id was often used to store Konami_ID
UPDATE public."Player_Transfer_Bids" b
SET player_id = btrim(b.direct_bid_id::text)
WHERE (b.player_id IS NULL OR btrim(b.player_id) = '')
  AND b.direct_bid_id IS NOT NULL
  AND btrim(b.direct_bid_id::text) <> '';

-- Listing bids: copy from listing
UPDATE public."Player_Transfer_Bids" b
SET player_id = l.player_id
FROM public."Player_Transfer_Listings" l
WHERE b.listing_id = l.id
  AND (b.player_id IS NULL OR btrim(b.player_id) = '')
  AND l.player_id IS NOT NULL
  AND btrim(l.player_id) <> '';

-- Auto-fill player_id on insert (from direct_bid_id or listing)
CREATE OR REPLACE FUNCTION public.trg_player_transfer_bids_set_player_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.player_id IS NULL OR btrim(NEW.player_id) = '' THEN
    IF NEW.direct_bid_id IS NOT NULL AND btrim(NEW.direct_bid_id::text) <> '' THEN
      NEW.player_id := btrim(NEW.direct_bid_id::text);
    ELSIF NEW.listing_id IS NOT NULL THEN
      SELECT l.player_id
      INTO NEW.player_id
      FROM public."Player_Transfer_Listings" l
      WHERE l.id = NEW.listing_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_bids_set_player_id ON public."Player_Transfer_Bids";
DROP TRIGGER IF EXISTS player_transfer_bids_01_set_player_id ON public."Player_Transfer_Bids";

CREATE TRIGGER player_transfer_bids_01_set_player_id
  BEFORE INSERT ON public."Player_Transfer_Bids"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_player_transfer_bids_set_player_id();

-- Direct-offer guard: one pending offer per player_id
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
    FROM public."Player_Transfer_Bids" b
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

DROP TRIGGER IF EXISTS player_transfer_bids_direct_offer_guard ON public."Player_Transfer_Bids";
DROP TRIGGER IF EXISTS player_transfer_bids_02_direct_offer_guard ON public."Player_Transfer_Bids";

CREATE TRIGGER player_transfer_bids_02_direct_offer_guard
  BEFORE INSERT ON public."Player_Transfer_Bids"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_player_transfer_bids_direct_offer_guard();

-- If you already applied transferengine_draft.sql, re-run it once so draft settlement
-- matches bids on player_id (see updated bid SELECT in that file).
