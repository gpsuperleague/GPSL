-- =============================================================================
-- Draft settlement — trust listing leader, not stale all-time bid rows
--
-- Bug: accept_draft_sale picked MAX(bid) across all is_direct rows for the
-- player_id (any past draft/test). Listing.current_highest_bidder reflects
-- THIS auction but could lose to an old higher bid with invalid buyer →
-- exception swallowed → draft_settled_count stays 0.
--
-- Run in SQL Editor, then:
--   SELECT public.transferengine_explain_draft_listing(
--     (SELECT id FROM "Player_Transfer_Listings"
--      WHERE listing_type='draft' AND status='Active' ORDER BY id LIMIT 1)
--   );
--   SELECT public.transferengine_probe_draft_settlement(3);
--   SELECT public.transferengine_run_report();
-- =============================================================================

CREATE OR REPLACE FUNCTION public.transferengine_normalize_club_short_name(p_club text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_in text := nullif(btrim(p_club), '');
  v_out text;
BEGIN
  IF v_in IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT c."ShortName"
  INTO v_out
  FROM public."Clubs" c
  WHERE c."ShortName" = v_in
     OR c."Club" = v_in
  LIMIT 1;

  RETURN coalesce(v_out, v_in);
END;
$function$;


CREATE OR REPLACE FUNCTION public.transferengine_explain_draft_listing(p_listing_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Player_Transfer_Listings"%rowtype;
  v_draft_start timestamptz;
  v_listing_buyer text;
  v_listing_amount numeric;
  v_listing_bid record;
  v_window_bid record;
  v_alltime_bid record;
  v_player record;
  v_season record;
BEGIN
  SELECT draft_auction_start_time INTO v_draft_start
  FROM public.global_settings WHERE id = 1;

  SELECT * INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'listing not found');
  END IF;

  v_listing_buyer := public.transferengine_normalize_club_short_name(
    v_listing.current_highest_bidder::text
  );
  v_listing_amount := v_listing.current_highest_bid;

  SELECT b.bid_amount, b.bidder_club_id, b.bid_time, b.listing_id
  INTO v_listing_bid
  FROM public."Player_Transfer_Bids" b
  WHERE b.is_direct = true
    AND b.listing_id = v_listing.id
    AND (v_draft_start IS NULL OR b.bid_time >= v_draft_start)
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  SELECT b.bid_amount, b.bidder_club_id, b.bid_time, b.listing_id
  INTO v_window_bid
  FROM public."Player_Transfer_Bids" b
  WHERE b.is_direct = true
    AND btrim(coalesce(b.player_id, b.direct_bid_id::text, '')) = btrim(v_listing.player_id::text)
    AND (v_draft_start IS NULL OR b.bid_time >= v_draft_start)
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  SELECT b.bid_amount, b.bidder_club_id, b.bid_time, b.listing_id
  INTO v_alltime_bid
  FROM public."Player_Transfer_Bids" b
  WHERE b.is_direct = true
    AND (
      b.listing_id = v_listing.id
      OR btrim(coalesce(b.player_id, b.direct_bid_id::text, '')) = btrim(v_listing.player_id::text)
    )
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  SELECT p."Konami_ID", p."Name", p."Contracted_Team"
  INTO v_player
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(v_listing.player_id::text);

  SELECT s.id, s.status
  INTO v_season
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'listing_id', v_listing.id,
    'player_id', v_listing.player_id,
    'listing_status', v_listing.status,
    'draft_auction_start_time', v_draft_start,
    'listing_leader', jsonb_build_object(
      'buyer', v_listing_buyer,
      'amount', v_listing_amount,
      'buyer_has_finances', v_listing_buyer IS NOT NULL AND EXISTS (
        SELECT 1 FROM public."Club_Finances" f WHERE f.club_name = v_listing_buyer
      )
    ),
    'top_bid_this_listing_in_window', jsonb_build_object(
      'buyer', public.transferengine_normalize_club_short_name(v_listing_bid.bidder_club_id::text),
      'amount', v_listing_bid.bid_amount,
      'bid_time', v_listing_bid.bid_time,
      'listing_id', v_listing_bid.listing_id
    ),
    'top_bid_player_in_window', jsonb_build_object(
      'buyer', public.transferengine_normalize_club_short_name(v_window_bid.bidder_club_id::text),
      'amount', v_window_bid.bid_amount,
      'bid_time', v_window_bid.bid_time,
      'listing_id', v_window_bid.listing_id
    ),
    'top_bid_alltime_legacy_query', jsonb_build_object(
      'buyer', public.transferengine_normalize_club_short_name(v_alltime_bid.bidder_club_id::text),
      'amount', v_alltime_bid.bid_amount,
      'bid_time', v_alltime_bid.bid_time,
      'listing_id', v_alltime_bid.listing_id,
      'differs_from_listing_leader',
        v_alltime_bid.bidder_club_id IS DISTINCT FROM v_listing.current_highest_bidder
        OR v_alltime_bid.bid_amount IS DISTINCT FROM v_listing.current_highest_bid
    ),
    'player', jsonb_build_object(
      'found', v_player."Konami_ID" IS NOT NULL,
      'name', v_player."Name",
      'contracted_team', v_player."Contracted_Team"
    ),
    'current_season', jsonb_build_object('id', v_season.id, 'status', v_season.status)
  );
END;
$function$;


CREATE OR REPLACE FUNCTION public.transferengine_accept_draft_sale(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Player_Transfer_Listings"%rowtype;
  v_amount  numeric;
  v_buyer   text;
  v_player  public."Players"%rowtype;
  v_history_id bigint;
  v_draft_start timestamptz;
  v_pid     text;
BEGIN
  SELECT draft_auction_start_time INTO v_draft_start
  FROM public.global_settings WHERE id = 1;

  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_listing.listing_type IS DISTINCT FROM 'draft' THEN
    RETURN;
  END IF;

  IF v_listing.status NOT IN ('Active', 'Review') THEN
    RETURN;
  END IF;

  -- THIS auction's leader (sync trigger) wins — not all-time max bid on player_id
  v_buyer := public.transferengine_normalize_club_short_name(
    v_listing.current_highest_bidder::text
  );
  v_amount := v_listing.current_highest_bid;

  IF v_buyer IS NULL OR v_amount IS NULL OR v_amount <= 0 THEN
    SELECT b.bid_amount, b.bidder_club_id
    INTO v_amount, v_buyer
    FROM public."Player_Transfer_Bids" b
    WHERE b.is_direct = true
      AND b.listing_id = v_listing.id
      AND (v_draft_start IS NULL OR b.bid_time >= v_draft_start)
    ORDER BY b.bid_amount DESC, b.bid_time ASC
    LIMIT 1;

    v_buyer := public.transferengine_normalize_club_short_name(v_buyer);
  END IF;

  IF v_buyer IS NULL OR v_amount IS NULL OR v_amount <= 0 THEN
    UPDATE public."Player_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = false
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  UPDATE public."Player_Transfer_Listings"
  SET current_highest_bid = v_amount,
      current_highest_bidder = v_buyer
  WHERE id = v_listing.id;

  v_pid := btrim(v_listing.player_id::text);

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    UPDATE public."Player_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = false
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  IF v_player."Contracted_Team" IS NOT NULL
     AND btrim(v_player."Contracted_Team"::text) <> '' THEN
    UPDATE public."Player_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = (btrim(v_player."Contracted_Team"::text) = v_buyer),
        winning_bid = CASE WHEN btrim(v_player."Contracted_Team"::text) = v_buyer THEN v_amount ELSE winning_bid END,
        winning_club = CASE WHEN btrim(v_player."Contracted_Team"::text) = v_buyer THEN v_buyer ELSE winning_club END
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Club_Finances" f WHERE f.club_name = v_buyer
  ) THEN
    RAISE EXCEPTION 'Club_Finances missing for buyer % (listing %)', v_buyer, p_listing_id;
  END IF;

  PERFORM public.assert_player_available_for_signing(v_pid);

  PERFORM public.player_assign_to_club(v_pid, v_buyer, NULL::numeric, false);

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
    v_pid,
    NULL,
    v_buyer,
    v_amount,
    0,
    now(),
    v_listing.id
  )
  RETURNING id INTO v_history_id;

  PERFORM public.post_transfer_ledger_for_history(v_history_id);

  UPDATE public."Player_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = true,
      winning_bid = v_amount,
      winning_club = v_buyer
  WHERE id = v_listing.id;
END;
$function$;


CREATE OR REPLACE FUNCTION public.transferengine_diagnose_draft_backlog()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_finish timestamptz;
  v_start timestamptz;
  v_season record;
BEGIN
  SELECT draft_auction_start_time, draft_random_finish_time
  INTO v_start, v_finish
  FROM public.global_settings WHERE id = 1;

  SELECT s.id, s.status
  INTO v_season
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'active_draft_listings', (
      SELECT count(*)::int FROM public."Player_Transfer_Listings" l
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
    ),
    'with_listing_leader', (
      SELECT count(*)::int FROM public."Player_Transfer_Listings" l
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
        AND l.current_highest_bidder IS NOT NULL
    ),
    'alltime_bid_beats_listing_leader', (
      SELECT count(*)::int
      FROM public."Player_Transfer_Listings" l
      CROSS JOIN LATERAL (
        SELECT public.transferengine_normalize_club_short_name(b.bidder_club_id::text) AS buyer
        FROM public."Player_Transfer_Bids" b
        WHERE b.is_direct = true
          AND (
            b.listing_id = l.id
            OR btrim(coalesce(b.player_id, b.direct_bid_id::text, '')) = btrim(l.player_id::text)
          )
        ORDER BY b.bid_amount DESC, b.bid_time ASC
        LIMIT 1
      ) top_bid
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
        AND l.current_highest_bidder IS NOT NULL
        AND top_bid.buyer IS DISTINCT FROM public.transferengine_normalize_club_short_name(l.current_highest_bidder::text)
    ),
    'alltime_bid_buyer_missing_finances', (
      SELECT count(*)::int
      FROM public."Player_Transfer_Listings" l
      CROSS JOIN LATERAL (
        SELECT b.bidder_club_id, b.bid_amount
        FROM public."Player_Transfer_Bids" b
        WHERE b.is_direct = true
          AND (
            b.listing_id = l.id
            OR btrim(coalesce(b.player_id, b.direct_bid_id::text, '')) = btrim(l.player_id::text)
          )
        ORDER BY b.bid_amount DESC, b.bid_time ASC
        LIMIT 1
      ) top_bid
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
        AND l.current_highest_bidder IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM public."Club_Finances" f
          WHERE f.club_name = public.transferengine_normalize_club_short_name(top_bid.bidder_club_id::text)
        )
        AND EXISTS (
          SELECT 1 FROM public."Club_Finances" f
          WHERE f.club_name = public.transferengine_normalize_club_short_name(l.current_highest_bidder::text)
        )
    ),
    'no_direct_bid_row', (
      SELECT count(*)::int
      FROM public."Player_Transfer_Listings" l
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
        AND l.current_highest_bidder IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM public."Player_Transfer_Bids" b
          WHERE b.is_direct = true
            AND b.listing_id = l.id
            AND (v_start IS NULL OR b.bid_time >= v_start)
        )
    ),
    'player_already_signed_elsewhere', (
      SELECT count(*)::int
      FROM public."Player_Transfer_Listings" l
      JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
        AND p."Contracted_Team" IS NOT NULL AND btrim(p."Contracted_Team"::text) <> ''
        AND btrim(p."Contracted_Team"::text) IS DISTINCT FROM btrim(l.current_highest_bidder::text)
    ),
    'buyer_missing_club_finances', (
      SELECT count(*)::int
      FROM public."Player_Transfer_Listings" l
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
        AND l.current_highest_bidder IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM public."Club_Finances" f
          WHERE f.club_name = public.transferengine_normalize_club_short_name(l.current_highest_bidder::text)
        )
    ),
    'ready_to_settle', (
      SELECT count(*)::int
      FROM public."Player_Transfer_Listings" l
      JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
        AND l.current_highest_bidder IS NOT NULL
        AND (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team"::text) = '')
        AND EXISTS (
          SELECT 1 FROM public."Club_Finances" f
          WHERE f.club_name = public.transferengine_normalize_club_short_name(l.current_highest_bidder::text)
        )
    ),
    'current_season_id', v_season.id,
    'current_season_status', v_season.status,
    'draft_auction_start_time', v_start,
    'draft_random_finish_time', v_finish
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transferengine_explain_draft_listing(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_explain_draft_listing(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.transferengine_normalize_club_short_name(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_normalize_club_short_name(text) TO service_role;

NOTIFY pgrst, 'reload schema';
