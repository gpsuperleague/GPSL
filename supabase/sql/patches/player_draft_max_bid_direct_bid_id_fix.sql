-- =============================================================================
-- Fix: player_draft_place_auto_bid inserted text Konami id into integer
-- direct_bid_id → "column direct_bid_id is of type integer but expression is
-- of type text" when setting a max bid on a thread that already has bids.
--
-- Safe re-run. Depends on auction_max_bids.sql (+ player_draft_ensure_listing).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.player_draft_place_auto_bid(
  p_club_short_name text,
  p_player_id text,
  p_amount numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_listing_id bigint;
  v_bounds record;
  v_has_bids boolean;
  v_has_mine boolean;
  v_is_first boolean;
  v_is_join boolean;
  v_consume boolean := false;
  v_credits int;
  v_leader text;
  v_min numeric;
BEGIN
  SELECT * INTO v_bounds FROM public.draft_auction_window_bounds();
  IF NOT v_bounds.draft_enabled OR v_bounds.draft_start IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'skipped', 'disabled');
  END IF;
  IF now() < v_bounds.draft_start OR now() >= v_bounds.draft_window_end THEN
    RETURN jsonb_build_object('ok', false, 'skipped', 'window_closed');
  END IF;

  v_min := public.player_draft_min_next_bid(v_pid);
  IF p_amount < v_min THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'below_min');
  END IF;

  SELECT b.bidder_club_id INTO v_leader
  FROM public."Player_Transfer_Bids" b
  WHERE coalesce(b.player_id, b.direct_bid_id::text) = v_pid
    AND b.is_direct = true
    AND b.seller_club_id IS NULL
    AND b.bid_time >= v_bounds.draft_start
    AND b.bid_time < v_bounds.draft_window_end
  ORDER BY b.bid_amount DESC, b.bid_time DESC
  LIMIT 1;

  IF v_leader IS NOT DISTINCT FROM p_club_short_name THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'already_leading');
  END IF;

  v_has_bids := v_leader IS NOT NULL;
  v_has_mine := public.player_draft_club_has_bid(p_club_short_name, v_pid);

  IF NOT v_has_bids THEN
    IF now() >= v_bounds.draft_cutoff THEN
      RETURN jsonb_build_object('ok', false, 'skipped', 'cutoff');
    END IF;
    v_is_first := true;
    v_is_join := false;
  ELSIF v_has_mine THEN
    v_is_first := false;
    v_is_join := EXISTS (
      SELECT 1 FROM public."Player_Transfer_Bids" b
      WHERE b.bidder_club_id = p_club_short_name
        AND coalesce(b.player_id, b.direct_bid_id::text) = v_pid
        AND b.is_draft_join = true
        AND b.bid_time >= v_bounds.draft_start
    );
  ELSE
    v_is_first := false;
    v_is_join := true;
    v_credits := public.club_draft_auction_credits(
      p_club_short_name,
      v_bounds.draft_start,
      v_bounds.draft_cutoff,
      v_bounds.draft_window_end
    );
    IF v_credits <= 0 THEN
      RETURN jsonb_build_object(
        'ok', false,
        'skipped', 'no_credits',
        'msg', 'Not enough draft credits to join this auction.'
      );
    END IF;
    v_consume := true;
  END IF;

  v_listing_id := public.player_draft_ensure_listing(v_pid);

  -- player_id holds Konami id (text). direct_bid_id is integer legacy — leave NULL.
  INSERT INTO public."Player_Transfer_Bids" (
    listing_id, player_id, direct_bid_id, bidder_club_id, seller_club_id,
    bid_amount, is_direct, is_first_draft_bid, is_draft_join, draft_join_consumed, bid_time
  )
  VALUES (
    v_listing_id, v_pid, NULL, p_club_short_name, NULL,
    p_amount, true, v_is_first, v_is_join, v_consume, now()
  );

  UPDATE public."Player_Transfer_Listings"
  SET current_highest_bid = p_amount,
      current_highest_bidder = p_club_short_name
  WHERE id = v_listing_id;

  RETURN jsonb_build_object('ok', true, 'bid_amount', p_amount, 'auto', true);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.player_draft_place_auto_bid(text, text, numeric) TO authenticated;
