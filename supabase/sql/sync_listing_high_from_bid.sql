-- Keep Player_Transfer_Listings.current_highest_* in sync when bids are inserted.
-- SECURITY DEFINER bypasses RLS. Re-run if you already applied an older version.
-- Run once in Supabase SQL Editor.

CREATE OR REPLACE FUNCTION public.trg_sync_listing_high_from_bid()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.listing_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.bidder_club_id IS NULL OR btrim(NEW.bidder_club_id::text) = '' THEN
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
    );

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_bids_sync_listing_high ON public."Player_Transfer_Bids";

CREATE TRIGGER player_transfer_bids_sync_listing_high
  AFTER INSERT ON public."Player_Transfer_Bids"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_sync_listing_high_from_bid();

ALTER TABLE public."Player_Transfer_Bids"
  ADD COLUMN IF NOT EXISTS is_opening_bid boolean DEFAULT false;

NOTIFY pgrst, 'reload schema';
