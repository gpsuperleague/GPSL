-- =============================================================================
-- Fix: allow bids on New Owner first-season transfer-list slots
--
-- Same-season signing lock correctly skips new_owner_slot listings when listing,
-- and accept_sale allows those sales — but trg_transfer_bid_block_same_season_player
-- was later replaced (contract expiry FA patch) without the new_owner_slot
-- exception, so Valencia-style bids on Barcelona new-owner lists failed with
-- "signed in the current season".
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.trg_listing_block_same_season_sale()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.player_id IS NULL OR btrim(NEW.player_id::text) = '' THEN
    RETURN NEW;
  END IF;

  -- Draft / FA auction threads are not club sales
  IF lower(coalesce(NEW.listing_type::text, '')) = 'draft'
     OR nullif(btrim(coalesce(NEW.seller_club_id::text, '')), '') IS NULL THEN
    RETURN NEW;
  END IF;

  -- New Owner first-season transfer list (one of 3 slots)
  IF coalesce(NEW.new_owner_slot, false) THEN
    RETURN NEW;
  END IF;

  -- Forced underperformance listings
  IF coalesce(NEW.perpetual_renew, false)
     AND coalesce(NEW.special_rules ->> 'source', '') = 'underperformance' THEN
    RETURN NEW;
  END IF;

  PERFORM public.assert_player_transferable(btrim(NEW.player_id::text));

  IF to_regprocedure('public.assert_player_available_for_signing(text)') IS NOT NULL THEN
    PERFORM public.assert_player_available_for_signing(btrim(NEW.player_id::text));
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_transfer_bid_block_same_season_player()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player_id text;
  v_new_owner_listing boolean := false;
  v_bidder text;
BEGIN
  v_player_id := btrim(coalesce(NEW.player_id::text, NEW.direct_bid_id::text, ''));

  IF NEW.listing_id IS NOT NULL THEN
    IF v_player_id = '' THEN
      SELECT btrim(l.player_id::text), coalesce(l.new_owner_slot, false)
      INTO v_player_id, v_new_owner_listing
      FROM public."Player_Transfer_Listings" l
      WHERE l.id = NEW.listing_id;
    ELSE
      SELECT coalesce(l.new_owner_slot, false)
      INTO v_new_owner_listing
      FROM public."Player_Transfer_Listings" l
      WHERE l.id = NEW.listing_id;
    END IF;
  END IF;

  IF v_player_id IS NULL OR v_player_id = '' THEN
    RETURN NEW;
  END IF;

  -- Bids on New Owner first-season list slots are allowed even if the player
  -- was signed this season (that is the point of the 3-slot exception).
  IF v_new_owner_listing THEN
    RETURN NEW;
  END IF;

  PERFORM public.assert_player_transferable(v_player_id);

  IF to_regprocedure('public.assert_player_available_for_signing(text)') IS NOT NULL THEN
    PERFORM public.assert_player_available_for_signing(v_player_id);
  END IF;

  v_bidder := nullif(btrim(coalesce(NEW.bidder_club_id::text, '')), '');
  IF v_bidder IS NOT NULL
     AND to_regprocedure('public.assert_club_may_sign_expiry_fa_player(text,text)') IS NOT NULL THEN
    PERFORM public.assert_club_may_sign_expiry_fa_player(v_player_id, v_bidder);
  END IF;

  RETURN NEW;
END;
$function$;

NOTIFY pgrst, 'reload schema';
