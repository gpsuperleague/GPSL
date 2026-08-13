-- =============================================================================
-- List anytime; bid only while transfer window is open
--
-- Owners may create standard transfer listings with the global TW shut.
-- Other clubs cannot place bids (or direct offers) until transfer_window_open.
-- Draft auction bids remain gated by the draft auction guards only.
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.trg_player_transfer_bids_transfer_window()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_open boolean;
  v_is_draft boolean;
BEGIN
  -- System / DEFINER paths that insert on behalf of another club
  IF current_setting('gpsl.bypass_bid_owner_check', true) = 'on' THEN
    RETURN NEW;
  END IF;

  -- Service jobs / SQL Editor (no JWT)
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  v_is_draft := (
    COALESCE(NEW.is_first_draft_bid, false)
    OR COALESCE(NEW.is_draft_join, false)
    OR (
      NEW.listing_id IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM public."Player_Transfer_Listings" l
        WHERE l.id = NEW.listing_id AND l.listing_type = 'draft'
      )
    )
    OR (COALESCE(NEW.is_direct, false) AND NEW.seller_club_id IS NULL)
  );

  IF v_is_draft THEN
    RETURN NEW;
  END IF;

  SELECT coalesce(transfer_window_open, false)
  INTO v_open
  FROM public.global_settings
  WHERE id = 1;

  IF NOT coalesce(v_open, false) THEN
    RAISE EXCEPTION
      'Transfer window is closed — bidding opens in June–August and January';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_bids_transfer_window
  ON public."Player_Transfer_Bids";

CREATE TRIGGER player_transfer_bids_transfer_window
  BEFORE INSERT ON public."Player_Transfer_Bids"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_player_transfer_bids_transfer_window();
