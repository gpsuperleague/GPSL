-- =============================================================================
-- Agent fee on TRANSFER LIST deals (Player_Transfer_Listings → accept_sale).
--
-- Transfer_History.agent_fee existed but every path wrote 0. This adds an
-- admin % (default 1%) of the winning fee, charged to the BUYER on top of the
-- fee. post_transfer_ledger_for_history already posts it as transfer_agent_fee
-- and includes it in the income tax base.
--
-- Not charged on: draft auctions, special auctions, foreign sales, contract
-- releases / expiry, forced releases (those paths keep agent_fee = 0).
-- No backdated charge on past transfers.
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- Requires the latest transferengine_accept_sale
-- (patches/transferengine_block_own_listing_bids.sql) — this replaces it.
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS transfer_agent_fee_pct numeric(6, 3) NOT NULL DEFAULT 1.000;

COMMENT ON COLUMN public.global_settings.transfer_agent_fee_pct IS
  'Agent fee % of the winning fee on transfer list deals, paid by the buyer on top of the fee. 0 = off.';

CREATE OR REPLACE FUNCTION public.transfer_agent_fee_for(p_fee numeric)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT round(
    greatest(coalesce(p_fee, 0), 0)
      * greatest(coalesce((SELECT g.transfer_agent_fee_pct FROM public.global_settings g WHERE g.id = 1), 0), 0)
      / 100.0,
    0
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_update_transfer_agent_fee_pct(p_pct numeric)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF p_pct IS NULL OR p_pct < 0 OR p_pct > 100 THEN
    RAISE EXCEPTION 'Agent fee %% must be between 0 and 100';
  END IF;

  UPDATE public.global_settings
  SET transfer_agent_fee_pct = p_pct,
      updated_at = now()
  WHERE id = 1;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Transfer list settlement (same as transferengine_block_own_listing_bids.sql
-- plus the agent fee on Transfer_History)
-- ---------------------------------------------------------------------------
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
  v_agent_fee        numeric;
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

  -- Prefer an external high bid (ignore seller self-bids)
  PERFORM public.transferengine_sync_listing_high_bid(p_listing_id);

  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id;

  v_fee := v_listing.current_highest_bid;
  v_buyer := upper(btrim(coalesce(v_listing.current_highest_bidder::text, '')));
  v_seller := upper(btrim(coalesce(v_listing.seller_club_id::text, '')));

  IF v_buyer = '' OR v_fee IS NULL THEN
    RAISE NOTICE 'No winning bid for listing %', p_listing_id;
    RETURN;
  END IF;

  IF v_buyer = v_seller THEN
    RAISE NOTICE 'Buyer equals seller for listing % — sale blocked', p_listing_id;
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

  IF v_player."Contracted_Team" IS DISTINCT FROM v_listing.seller_club_id
     AND upper(btrim(coalesce(v_player."Contracted_Team", ''))) IS DISTINCT FROM v_seller THEN
    IF upper(btrim(coalesce(v_player."Contracted_Team", ''))) = v_buyer
       AND EXISTS (
         SELECT 1
         FROM public."Transfer_History" h
         WHERE h.listing_id = v_listing.id
       ) THEN
      UPDATE public."Player_Transfer_Listings"
      SET status = 'Closed',
          transfer_completed = true,
          winning_bid = coalesce(v_fee, v_listing.winning_bid),
          winning_club = coalesce(v_listing.current_highest_bidder, v_listing.winning_club)
      WHERE id = v_listing.id
        AND status IN ('Active', 'Review');
      RAISE NOTICE 'Listing % already transferred — closed listing only', p_listing_id;
      RETURN;
    END IF;

    RAISE NOTICE 'Player no longer at selling club for listing %', p_listing_id;
    RETURN;
  END IF;

  v_allow_same_season :=
    coalesce(v_listing.new_owner_slot, false)
    OR coalesce(v_listing.perpetual_renew, false)
    OR coalesce(v_listing.special_rules ->> 'new_owner_list', '') = 'true'
    OR coalesce(v_listing.special_rules ->> 'source', '') = 'underperformance';

  IF NOT v_allow_same_season
     AND public.player_signed_this_season(v_player."Season_Signed") THEN
    RAISE NOTICE 'Player signed this season — sale blocked for listing %', p_listing_id;
    RETURN;
  END IF;

  PERFORM public.player_assign_to_club(
    v_listing.player_id::text,
    v_listing.current_highest_bidder,
    NULL::numeric,
    false
  );

  v_agent_fee := CASE
    WHEN v_buyer = 'FOREIGN' THEN 0
    ELSE public.transfer_agent_fee_for(v_fee)
  END;

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
    v_listing.seller_club_id,
    v_listing.current_highest_bidder,
    v_fee,
    coalesce(v_agent_fee, 0),
    now(),
    v_listing.id
  )
  RETURNING id INTO v_history_id;

  IF to_regprocedure('public.post_transfer_ledger_for_history(bigint)') IS NOT NULL THEN
    PERFORM public.post_transfer_ledger_for_history(v_history_id);
  ELSIF to_regprocedure('public.post_transfer_ledger_for_history(bigint, boolean)') IS NOT NULL THEN
    PERFORM public.post_transfer_ledger_for_history(v_history_id, true);
  ELSE
    UPDATE public."Club_Finances"
    SET balance = balance - v_fee - coalesce(v_agent_fee, 0)
    WHERE club_name = v_listing.current_highest_bidder;
    UPDATE public."Club_Finances"
    SET balance = balance + v_fee
    WHERE club_name = v_listing.seller_club_id;
  END IF;

  UPDATE public."Player_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = true,
      winning_bid = v_fee,
      winning_club = v_listing.current_highest_bidder
  WHERE id = v_listing.id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transfer_agent_fee_for(numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_transfer_agent_fee_pct(numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_accept_sale(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
