-- =============================================================================
-- Fix: New Owner first-season listings stuck after 7pm
--
-- Bug: player_new_owner_transfer_list allows same-season signings, and bids are
-- allowed on new_owner_slot listings — but transferengine_accept_sale still
-- blocked "signed this season" and silently RETURN'd. Result stayed Active past
-- end_time (hidden on Transfer Market, visible in Transfer Centre), slot never
-- refunded, player never moved.
--
-- Also keeps underperformance perpetual_renew exception.
-- Uses central-bank ledger settlement (post_transfer_ledger_for_history).
--
-- Run once in Supabase SQL Editor, then run the Honda repair section (or
-- SELECT public.transferengine_run(); for all stuck listings).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.transferengine_accept_sale(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing          public."Player_Transfer_Listings"%rowtype;
  v_player           public."Players"%rowtype;
  v_history_id       bigint;
  v_fee              numeric;
  v_buyer            text;
  v_seller           text;
  v_allow_same_season boolean := false;
BEGIN
  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Listing % not found', p_listing_id;
    RETURN;
  END IF;

  IF v_listing.status NOT IN ('Active', 'Review') THEN
    RAISE NOTICE 'Listing % already processed', p_listing_id;
    RETURN;
  END IF;

  v_fee := v_listing.current_highest_bid;
  v_buyer := v_listing.current_highest_bidder;
  v_seller := v_listing.seller_club_id;

  IF v_buyer IS NULL OR v_fee IS NULL THEN
    RAISE NOTICE 'No winning bid for listing %', p_listing_id;
    RETURN;
  END IF;

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_listing.player_id::text
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Player not found for listing %', p_listing_id;
    RETURN;
  END IF;

  IF v_player."Contracted_Team" IS DISTINCT FROM v_seller THEN
    -- Partial prior run: player already assigned to buyer, listing still open
    IF v_player."Contracted_Team" IS NOT DISTINCT FROM v_buyer
       AND EXISTS (
         SELECT 1
         FROM public."Transfer_History" h
         WHERE h.listing_id = v_listing.id
       ) THEN
      UPDATE public."Player_Transfer_Listings"
      SET status = 'Closed',
          transfer_completed = true,
          winning_bid = coalesce(v_fee, v_listing.winning_bid),
          winning_club = coalesce(v_buyer, v_listing.winning_club)
      WHERE id = v_listing.id
        AND status IN ('Active', 'Review');
      RAISE NOTICE 'Listing % already transferred — closed listing only', p_listing_id;
      RETURN;
    END IF;

    RAISE NOTICE 'Player no longer at selling club for listing %', p_listing_id;
    RETURN;
  END IF;

  -- Same-season lock does NOT apply to:
  --   - New Owner first-season transfer list (new_owner_slot)
  --   - Underperformance perpetual renew listings
  v_allow_same_season :=
    coalesce(v_listing.new_owner_slot, false)
    OR coalesce(v_listing.perpetual_renew, false)
    OR coalesce(v_listing.special_rules ->> 'new_owner_list', '') = 'true'
    OR (
      coalesce(v_listing.special_rules ->> 'source', '') = 'underperformance'
    );

  IF NOT v_allow_same_season
     AND public.player_signed_this_season(v_player."Season_Signed") THEN
    RAISE NOTICE 'Player signed this season — sale blocked for listing %', p_listing_id;
    RETURN;
  END IF;

  -- Disambiguate overloads: (text, text) vs (text, text, numeric) vs 4-arg
  PERFORM public.player_assign_to_club(
    v_listing.player_id::text,
    v_buyer,
    NULL::numeric,
    false
  );

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
    v_listing.player_id,
    v_seller,
    v_buyer,
    v_fee,
    0,
    now(),
    v_listing.id
  )
  RETURNING id INTO v_history_id;

  IF to_regprocedure('public.post_transfer_ledger_for_history(bigint)') IS NOT NULL THEN
    PERFORM public.post_transfer_ledger_for_history(v_history_id);
  ELSIF to_regprocedure('public.post_transfer_ledger_for_history(bigint, boolean)') IS NOT NULL THEN
    PERFORM public.post_transfer_ledger_for_history(v_history_id, true);
  ELSE
    -- Legacy fallback: direct balances
    UPDATE public."Club_Finances"
    SET balance = balance - v_fee
    WHERE club_name = v_buyer;
    UPDATE public."Club_Finances"
    SET balance = balance + v_fee
    WHERE club_name = v_seller;
  END IF;

  UPDATE public."Player_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = true,
      winning_bid = v_fee,
      winning_club = v_buyer
  WHERE id = v_listing.id;
END;
$function$;

-- If accept_sale still fails after bid >= reserve, do not leave listing Active forever.
-- Move to Review so Transfer Centre can act (or admin can re-run).
CREATE OR REPLACE FUNCTION public.transferengine_evaluate_expired_listing(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Player_Transfer_Listings"%rowtype;
  v_now timestamptz := now();
  v_status text;
BEGIN
  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Listing % not found in evaluate_expired_listing', p_listing_id;
    RETURN;
  END IF;

  PERFORM public.transferengine_sync_listing_high_bid(p_listing_id);

  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id;

  IF v_listing.current_highest_bid IS NULL THEN
    IF coalesce(v_listing.perpetual_renew, false)
       AND to_regprocedure('public.transferengine_perpetual_relist(bigint)') IS NOT NULL THEN
      PERFORM public.transferengine_perpetual_relist(p_listing_id);
    ELSE
      UPDATE public."Player_Transfer_Listings"
      SET status = 'Closed',
          transfer_completed = false
      WHERE id = v_listing.id;
    END IF;
    RETURN;
  END IF;

  IF v_listing.current_highest_bid >= v_listing.reserve_price THEN
    PERFORM public.transferengine_accept_sale(v_listing.id);

    SELECT status INTO v_status
    FROM public."Player_Transfer_Listings"
    WHERE id = v_listing.id;

    -- Accept failed silently — surface for seller/admin instead of infinite Active loop
    IF v_status = 'Active' THEN
      UPDATE public."Player_Transfer_Listings"
      SET status = 'Review',
          seller_review_deadline = v_now + interval '24 hours'
      WHERE id = v_listing.id
        AND status = 'Active';
      RAISE NOTICE
        'Listing % accept_sale did not complete — moved to Review',
        v_listing.id;
    END IF;
    RETURN;
  END IF;

  UPDATE public."Player_Transfer_Listings"
  SET status = 'Review',
      seller_review_deadline = v_now + interval '24 hours'
  WHERE id = v_listing.id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Fix nested UPDATE from BEFORE trigger (tuple already modified)
-- new_owner_listing_settle_slot must NOT UPDATE Player_Transfer_Listings —
-- the BEFORE trigger sets NEW.new_owner_slot_settled; only restore club slots.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.new_owner_listing_settle_slot(
  p_listing_id bigint,
  p_sold boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Player_Transfer_Listings"%rowtype;
BEGIN
  SELECT * INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND OR coalesce(v_listing.new_owner_slot, false) IS NOT TRUE THEN
    RETURN;
  END IF;

  IF coalesce(v_listing.new_owner_slot_settled, false) THEN
    RETURN;
  END IF;

  -- Sold: slot stays consumed. Do not UPDATE the listing here (BEFORE trigger
  -- already sets NEW.new_owner_slot_settled — nested UPDATE causes 27000).
  IF p_sold THEN
    RETURN;
  END IF;

  -- Unsold close: refund the first-season slot to the club only.
  PERFORM public.club_new_owner_slot_restore(v_listing.seller_club_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_player_transfer_listings_new_owner_slot()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF coalesce(NEW.new_owner_slot, false) IS NOT TRUE THEN
    RETURN NEW;
  END IF;

  IF coalesce(NEW.new_owner_slot_settled, false) THEN
    RETURN NEW;
  END IF;

  IF coalesce(NEW.transfer_completed, false) IS TRUE
    AND coalesce(OLD.transfer_completed, false) IS DISTINCT FROM TRUE THEN
    PERFORM public.new_owner_listing_settle_slot(NEW.id, true);
    NEW.new_owner_slot_settled := true;
    RETURN NEW;
  END IF;

  IF NEW.status = 'Closed'
    AND coalesce(NEW.transfer_completed, false) IS NOT TRUE
    AND (
      OLD.status IS DISTINCT FROM 'Closed'
      OR coalesce(OLD.transfer_completed, false) IS DISTINCT FROM false
    ) THEN
    PERFORM public.new_owner_listing_settle_slot(NEW.id, false);
    NEW.new_owner_slot_settled := true;
  END IF;

  RETURN NEW;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transferengine_accept_sale(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_evaluate_expired_listing(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.new_owner_listing_settle_slot(bigint, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Repair: stuck New Owner / evening listings (Honda @ Jubilo and any similar)
-- Preview first, then settle.
-- ---------------------------------------------------------------------------

-- A) Preview stuck expired Active listings with a bid >= reserve
SELECT
  l.id,
  p."Name" AS player,
  l.seller_club_id,
  l.current_highest_bidder AS buyer,
  l.current_highest_bid,
  l.reserve_price,
  l.new_owner_slot,
  l.perpetual_renew,
  l.end_time,
  public.player_signed_this_season(p."Season_Signed") AS signed_this_season,
  p."Season_Signed",
  p."Contracted_Team"
FROM public."Player_Transfer_Listings" l
LEFT JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
WHERE l.status = 'Active'
  AND l.listing_type IS DISTINCT FROM 'draft'
  AND l.end_time <= now()
  AND l.current_highest_bid IS NOT NULL
  AND l.current_highest_bid >= coalesce(l.reserve_price, 0)
ORDER BY l.end_time;

-- B) Sync high bids, then settle all expired standard listings (uses fixed accept_sale)
SELECT public.transferengine_sync_listing_high_bid(l.id)
FROM public."Player_Transfer_Listings" l
WHERE l.status = 'Active'
  AND l.listing_type IS DISTINCT FROM 'draft'
  AND l.end_time <= now();

SELECT public.transferengine_run();

-- C) Confirm Honda / recent sales
SELECT
  h.transfer_time,
  p."Name" AS player,
  h.seller_club_id,
  h.buyer_club_id,
  h.fee,
  h.listing_id
FROM public."Transfer_History" h
LEFT JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
WHERE h.transfer_time >= now() - interval '48 hours'
   OR p."Name" ILIKE '%Honda%'
ORDER BY h.transfer_time DESC
LIMIT 30;

-- D) Jubilo new-owner slot remaining (should no longer be stuck on Honda listing)
SELECT
  c."ShortName",
  c.new_owner_releases_remaining,
  (
    SELECT count(*)::int
    FROM public."Player_Transfer_Listings" l
    WHERE l.seller_club_id = c."ShortName"
      AND coalesce(l.new_owner_slot, false) = true
      AND coalesce(l.new_owner_slot_settled, false) = false
      AND l.status IN ('Active', 'Review', 'Seller Review')
  ) AS active_new_owner_listings
FROM public."Clubs" c
WHERE c."ShortName" ILIKE '%Jubilo%';
