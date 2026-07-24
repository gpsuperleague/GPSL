-- =============================================================================
-- Admin: cancel open transfer listings / draft bids / direct offers
--
-- Open only — never touches completed sales (transfer_completed = true).
-- Soft cancel: listings → Closed; bids / direct offers → rejected.
--
-- RPCs:
--   admin_cancel_open_transfers_preview(...)
--   admin_cancel_open_transfers(..., p_confirm := true)
--
-- Scopes (p_scope):
--   market         — standard + direct listings (Active / Review / Seller Review)
--   draft          — player draft listings + their bids
--   direct_offers  — pending direct offers (no listing yet)
--   manager_draft  — manager draft listings + bids
--   all            — all of the above
--
-- Optional filters (AND with scope):
--   p_listing_id, p_player_id, p_seller_club, p_manager_id (manager draft)
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_cancel_open_transfers_preview(
  p_scope text DEFAULT 'all',
  p_listing_id bigint DEFAULT NULL,
  p_player_id text DEFAULT NULL,
  p_seller_club text DEFAULT NULL,
  p_manager_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_scope text := lower(btrim(coalesce(p_scope, 'all')));
  v_player text := nullif(btrim(coalesce(p_player_id, '')), '');
  v_seller text := nullif(upper(btrim(coalesce(p_seller_club, ''))), '');
  v_manager text := nullif(btrim(coalesce(p_manager_id, '')), '');
  v_market_listings int := 0;
  v_market_bids int := 0;
  v_draft_listings int := 0;
  v_draft_bids int := 0;
  v_direct_offers int := 0;
  v_mgr_listings int := 0;
  v_mgr_bids int := 0;
  v_perpetual int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_scope NOT IN ('market', 'draft', 'direct_offers', 'manager_draft', 'all') THEN
    RAISE EXCEPTION 'Invalid scope "%". Use market, draft, direct_offers, manager_draft, or all.', p_scope;
  END IF;

  IF v_scope IN ('market', 'all') THEN
    SELECT count(*)::int
    INTO v_market_listings
    FROM public."Player_Transfer_Listings" l
    WHERE l.status IN ('Active', 'Review', 'Seller Review')
      AND coalesce(l.transfer_completed, false) IS NOT TRUE
      AND lower(coalesce(l.listing_type, 'standard')) IN ('standard', 'direct')
      AND (p_listing_id IS NULL OR l.id = p_listing_id)
      AND (v_player IS NULL OR btrim(l.player_id::text) = v_player)
      AND (
        v_seller IS NULL
        OR upper(btrim(coalesce(l.seller_club_id::text, ''))) = v_seller
      );

    SELECT count(*)::int
    INTO v_market_bids
    FROM public."Player_Transfer_Bids" b
    WHERE lower(coalesce(b.status::text, '')) = 'active'
      AND b.listing_id IN (
        SELECT l.id
        FROM public."Player_Transfer_Listings" l
        WHERE l.status IN ('Active', 'Review', 'Seller Review')
          AND coalesce(l.transfer_completed, false) IS NOT TRUE
          AND lower(coalesce(l.listing_type, 'standard')) IN ('standard', 'direct')
          AND (p_listing_id IS NULL OR l.id = p_listing_id)
          AND (v_player IS NULL OR btrim(l.player_id::text) = v_player)
          AND (
            v_seller IS NULL
            OR upper(btrim(coalesce(l.seller_club_id::text, ''))) = v_seller
          )
      );

    SELECT count(*)::int
    INTO v_perpetual
    FROM public."Player_Transfer_Listings" l
    WHERE l.status IN ('Active', 'Review', 'Seller Review')
      AND coalesce(l.transfer_completed, false) IS NOT TRUE
      AND lower(coalesce(l.listing_type, 'standard')) IN ('standard', 'direct')
      AND coalesce(l.perpetual_renew, false) IS TRUE
      AND (p_listing_id IS NULL OR l.id = p_listing_id)
      AND (v_player IS NULL OR btrim(l.player_id::text) = v_player)
      AND (
        v_seller IS NULL
        OR upper(btrim(coalesce(l.seller_club_id::text, ''))) = v_seller
      );
  END IF;

  IF v_scope IN ('draft', 'all') THEN
    SELECT count(*)::int
    INTO v_draft_listings
    FROM public."Player_Transfer_Listings" l
    WHERE l.status IN ('Active', 'Review', 'Seller Review')
      AND coalesce(l.transfer_completed, false) IS NOT TRUE
      AND lower(coalesce(l.listing_type, '')) = 'draft'
      AND (p_listing_id IS NULL OR l.id = p_listing_id)
      AND (v_player IS NULL OR btrim(l.player_id::text) = v_player)
      AND (
        v_seller IS NULL
        OR upper(btrim(coalesce(l.seller_club_id::text, ''))) = v_seller
      );

    SELECT count(*)::int
    INTO v_draft_bids
    FROM public."Player_Transfer_Bids" b
    WHERE lower(coalesce(b.status::text, '')) = 'active'
      AND (
        b.listing_id IN (
          SELECT l.id
          FROM public."Player_Transfer_Listings" l
          WHERE lower(coalesce(l.listing_type, '')) = 'draft'
            AND coalesce(l.transfer_completed, false) IS NOT TRUE
            AND (p_listing_id IS NULL OR l.id = p_listing_id)
            AND (v_player IS NULL OR btrim(l.player_id::text) = v_player)
            AND (
              v_seller IS NULL
              OR upper(btrim(coalesce(l.seller_club_id::text, ''))) = v_seller
            )
        )
        OR (
          p_listing_id IS NULL
          AND v_seller IS NULL
          AND b.listing_id IS NULL
          AND coalesce(b.is_direct, false) IS NOT TRUE
          AND (
            v_player IS NULL
            OR btrim(coalesce(b.player_id, b.direct_bid_id::text, '')) = v_player
          )
        )
      );
  END IF;

  IF v_scope IN ('direct_offers', 'all') THEN
    SELECT count(*)::int
    INTO v_direct_offers
    FROM public."Player_Transfer_Bids" b
    WHERE coalesce(b.is_direct, false) IS TRUE
      AND b.listing_id IS NULL
      AND lower(coalesce(b.status::text, '')) = 'active'
      AND (v_player IS NULL OR btrim(coalesce(b.player_id, b.direct_bid_id::text, '')) = v_player)
      AND (
        v_seller IS NULL
        OR upper(btrim(coalesce(b.seller_club_id::text, ''))) = v_seller
      );
  END IF;

  IF v_scope IN ('manager_draft', 'all')
     AND to_regclass('public."Manager_Transfer_Listings"') IS NOT NULL THEN
    SELECT count(*)::int
    INTO v_mgr_listings
    FROM public."Manager_Transfer_Listings" l
    WHERE l.status = 'Active'
      AND lower(coalesce(l.listing_type, 'draft')) = 'draft'
      AND (p_listing_id IS NULL OR l.id = p_listing_id)
      AND (v_manager IS NULL OR btrim(l.manager_id::text) = v_manager);

    SELECT count(*)::int
    INTO v_mgr_bids
    FROM public."Manager_Transfer_Bids" b
    WHERE b.listing_id IN (
      SELECT l.id
      FROM public."Manager_Transfer_Listings" l
      WHERE l.status = 'Active'
        AND lower(coalesce(l.listing_type, 'draft')) = 'draft'
        AND (p_listing_id IS NULL OR l.id = p_listing_id)
        AND (v_manager IS NULL OR btrim(l.manager_id::text) = v_manager)
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'scope', v_scope,
    'filters', jsonb_build_object(
      'listing_id', p_listing_id,
      'player_id', v_player,
      'seller_club', v_seller,
      'manager_id', v_manager
    ),
    'market_listings', v_market_listings,
    'market_bids', v_market_bids,
    'draft_listings', v_draft_listings,
    'draft_bids', v_draft_bids,
    'direct_offers', v_direct_offers,
    'manager_draft_listings', v_mgr_listings,
    'manager_draft_bids', v_mgr_bids,
    'perpetual_renew_listings', v_perpetual,
    'total_items',
      v_market_listings + v_draft_listings + v_direct_offers + v_mgr_listings
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_cancel_open_transfers(
  p_scope text DEFAULT 'all',
  p_listing_id bigint DEFAULT NULL,
  p_player_id text DEFAULT NULL,
  p_seller_club text DEFAULT NULL,
  p_manager_id text DEFAULT NULL,
  p_confirm boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_scope text := lower(btrim(coalesce(p_scope, 'all')));
  v_player text := nullif(btrim(coalesce(p_player_id, '')), '');
  v_seller text := nullif(upper(btrim(coalesce(p_seller_club, ''))), '');
  v_manager text := nullif(btrim(coalesce(p_manager_id, '')), '');
  v_preview jsonb;
  v_market_listings int := 0;
  v_market_bids int := 0;
  v_draft_listings int := 0;
  v_draft_bids int := 0;
  v_direct_offers int := 0;
  v_mgr_listings int := 0;
  v_mgr_bids int := 0;
  v_ids bigint[];
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF NOT coalesce(p_confirm, false) THEN
    RAISE EXCEPTION 'Set p_confirm := true after reviewing preview counts';
  END IF;

  IF v_scope NOT IN ('market', 'draft', 'direct_offers', 'manager_draft', 'all') THEN
    RAISE EXCEPTION 'Invalid scope "%". Use market, draft, direct_offers, manager_draft, or all.', p_scope;
  END IF;

  v_preview := public.admin_cancel_open_transfers_preview(
    v_scope, p_listing_id, v_player, v_seller, v_manager
  );

  IF v_scope IN ('market', 'all') THEN
    SELECT coalesce(array_agg(l.id), ARRAY[]::bigint[])
    INTO v_ids
    FROM public."Player_Transfer_Listings" l
    WHERE l.status IN ('Active', 'Review', 'Seller Review')
      AND coalesce(l.transfer_completed, false) IS NOT TRUE
      AND lower(coalesce(l.listing_type, 'standard')) IN ('standard', 'direct')
      AND (p_listing_id IS NULL OR l.id = p_listing_id)
      AND (v_player IS NULL OR btrim(l.player_id::text) = v_player)
      AND (
        v_seller IS NULL
        OR upper(btrim(coalesce(l.seller_club_id::text, ''))) = v_seller
      );

    UPDATE public."Player_Transfer_Bids" b
    SET status = 'rejected'
    WHERE lower(coalesce(b.status::text, '')) = 'active'
      AND b.listing_id = ANY (v_ids);
    GET DIAGNOSTICS v_market_bids = ROW_COUNT;

    UPDATE public."Player_Transfer_Listings" l
    SET status = 'Closed',
        transfer_completed = false,
        winning_bid = null,
        winning_club = null,
        current_highest_bid = null,
        current_highest_bidder = null
    WHERE l.id = ANY (v_ids);
    GET DIAGNOSTICS v_market_listings = ROW_COUNT;
  END IF;

  IF v_scope IN ('draft', 'all') THEN
    SELECT coalesce(array_agg(l.id), ARRAY[]::bigint[])
    INTO v_ids
    FROM public."Player_Transfer_Listings" l
    WHERE l.status IN ('Active', 'Review', 'Seller Review')
      AND coalesce(l.transfer_completed, false) IS NOT TRUE
      AND lower(coalesce(l.listing_type, '')) = 'draft'
      AND (p_listing_id IS NULL OR l.id = p_listing_id)
      AND (v_player IS NULL OR btrim(l.player_id::text) = v_player)
      AND (
        v_seller IS NULL
        OR upper(btrim(coalesce(l.seller_club_id::text, ''))) = v_seller
      );

    UPDATE public."Player_Transfer_Bids" b
    SET status = 'rejected'
    WHERE lower(coalesce(b.status::text, '')) = 'active'
      AND (
        b.listing_id = ANY (v_ids)
        OR (
          p_listing_id IS NULL
          AND v_seller IS NULL
          AND b.listing_id IS NULL
          AND coalesce(b.is_direct, false) IS NOT TRUE
          AND (
            v_player IS NULL
            OR btrim(coalesce(b.player_id, b.direct_bid_id::text, '')) = v_player
          )
        )
      );
    GET DIAGNOSTICS v_draft_bids = ROW_COUNT;

    UPDATE public."Player_Transfer_Listings" l
    SET status = 'Closed',
        transfer_completed = false,
        winning_bid = null,
        winning_club = null,
        current_highest_bid = null,
        current_highest_bidder = null
    WHERE l.id = ANY (v_ids);
    GET DIAGNOSTICS v_draft_listings = ROW_COUNT;
  END IF;

  IF v_scope IN ('direct_offers', 'all') THEN
    UPDATE public."Player_Transfer_Bids" b
    SET status = 'rejected'
    WHERE coalesce(b.is_direct, false) IS TRUE
      AND b.listing_id IS NULL
      AND lower(coalesce(b.status::text, '')) = 'active'
      AND (v_player IS NULL OR btrim(coalesce(b.player_id, b.direct_bid_id::text, '')) = v_player)
      AND (
        v_seller IS NULL
        OR upper(btrim(coalesce(b.seller_club_id::text, ''))) = v_seller
      );
    GET DIAGNOSTICS v_direct_offers = ROW_COUNT;
  END IF;

  IF v_scope IN ('manager_draft', 'all')
     AND to_regclass('public."Manager_Transfer_Listings"') IS NOT NULL THEN
    SELECT coalesce(array_agg(l.id), ARRAY[]::bigint[])
    INTO v_ids
    FROM public."Manager_Transfer_Listings" l
    WHERE l.status = 'Active'
      AND lower(coalesce(l.listing_type, 'draft')) = 'draft'
      AND (p_listing_id IS NULL OR l.id = p_listing_id)
      AND (v_manager IS NULL OR btrim(l.manager_id::text) = v_manager);

    -- Manager_Transfer_Bids has no status column — delete open auction bids.
    DELETE FROM public."Manager_Transfer_Bids" b
    WHERE b.listing_id = ANY (v_ids);
    GET DIAGNOSTICS v_mgr_bids = ROW_COUNT;

    UPDATE public."Manager_Transfer_Listings" l
    SET status = 'Closed',
        transfer_completed = false,
        current_highest_bid = null,
        current_highest_bidder = null,
        updated_at = now()
    WHERE l.id = ANY (v_ids);
    GET DIAGNOSTICS v_mgr_listings = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'scope', v_scope,
    'preview', v_preview,
    'cancelled', jsonb_build_object(
      'market_listings', v_market_listings,
      'market_bids', v_market_bids,
      'draft_listings', v_draft_listings,
      'draft_bids', v_draft_bids,
      'direct_offers', v_direct_offers,
      'manager_draft_listings', v_mgr_listings,
      'manager_draft_bids', v_mgr_bids
    )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_cancel_open_transfers_preview(text, bigint, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_cancel_open_transfers(text, bigint, text, text, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_cancel_open_transfers_preview(text, bigint, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_cancel_open_transfers(text, bigint, text, text, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_cancel_open_transfers_preview(text, bigint, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.admin_cancel_open_transfers(text, bigint, text, text, text, boolean) TO service_role;

NOTIFY pgrst, 'reload schema';
