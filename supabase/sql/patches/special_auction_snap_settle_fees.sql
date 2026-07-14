-- =============================================================================
-- Special auction snap — clean per-bid fees on settle
--
-- fee_charged on each bid row = fee for that bid only:
--   winner club: 100% of snap_bid_fee per bid
--   losers:      25% of snap_bid_fee per bid
-- Purchase (discounted winning bid) stays on special_auctions.winner_purchase_amount
-- (not stuffed into the winning bid's fee_charged).
--
-- Run after special_auction_snap_v2.sql. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.special_auction_settle(p_auction_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_auction public.special_auctions%rowtype;
  v_win_club text;
  v_win_amount numeric;
  v_win_bid_id bigint;
  v_first_bid timestamptz;
  v_discount numeric := 0;
  v_purchase numeric := 0;
  v_club text;
  v_bid_count int;
  v_fee_total numeric;
  v_fee_charge numeric;
  v_unit_fee numeric;
  v_balance numeric;
  v_row_fee numeric;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_auction FROM public.special_auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Auction not found'; END IF;

  IF v_auction.auction_type = 'lowest_unique' THEN
    IF v_auction.status = 'active' THEN
      PERFORM public.special_auction_reveal_lowest_unique(p_auction_id);
      SELECT * INTO v_auction FROM public.special_auctions WHERE id = p_auction_id;
    END IF;
    IF v_auction.status NOT IN ('revealed', 'settled') THEN
      RAISE EXCEPTION 'Reveal the lowest unique auction first';
    END IF;
    v_win_club := v_auction.winning_club_id;
    v_win_amount := v_auction.winning_amount;

    IF v_win_club IS NULL THEN
      UPDATE public.special_auctions SET status = 'settled', updated_at = now() WHERE id = p_auction_id;
      RETURN;
    END IF;

    SELECT balance INTO v_balance FROM public."Club_Finances" WHERE club_name = v_win_club FOR UPDATE;
    UPDATE public."Club_Finances"
    SET balance = coalesce(v_balance, 0) - v_win_amount
    WHERE club_name = v_win_club;

    UPDATE public.special_auction_bids
    SET fee_charged = v_win_amount, is_winner = (club_id = v_win_club)
    WHERE auction_id = p_auction_id;

    PERFORM public.special_auction_award_prize(v_auction, v_win_club, v_win_amount);
    UPDATE public.special_auctions SET status = 'settled', updated_at = now() WHERE id = p_auction_id;
    RETURN;
  END IF;

  -- Snap
  IF v_auction.auction_type <> 'snap' THEN
    RAISE EXCEPTION 'Unknown auction type';
  END IF;

  SELECT b.id, b.club_id, b.bid_amount
  INTO v_win_bid_id, v_win_club, v_win_amount
  FROM public.special_auction_bids b
  WHERE b.auction_id = p_auction_id
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  UPDATE public.special_auction_bids SET is_winner = false WHERE auction_id = p_auction_id;
  IF v_win_club IS NOT NULL THEN
    UPDATE public.special_auction_bids SET is_winner = true WHERE id = v_win_bid_id;

    SELECT min(b.bid_time) INTO v_first_bid
    FROM public.special_auction_bids b
    WHERE b.auction_id = p_auction_id AND b.club_id = v_win_club;

    v_discount := public.special_auction_snap_discount_pct(v_auction.start_time, v_first_bid);
    v_purchase := round(coalesce(v_win_amount, 0) * (1 - v_discount / 100.0));
  END IF;

  v_unit_fee := coalesce(nullif(v_auction.snap_bid_fee, 0), 300000);

  FOR v_club, v_bid_count IN
    SELECT b.club_id, count(*)::int
    FROM public.special_auction_bids b
    WHERE b.auction_id = p_auction_id
    GROUP BY b.club_id
  LOOP
    v_fee_total := v_bid_count * v_unit_fee;
    IF v_club = v_win_club THEN
      v_fee_charge := v_fee_total + coalesce(v_purchase, 0);
      v_row_fee := v_unit_fee;
    ELSE
      v_fee_charge := round(v_fee_total * 0.25);
      v_row_fee := round(v_unit_fee * 0.25);
    END IF;

    SELECT balance INTO v_balance
    FROM public."Club_Finances"
    WHERE club_name = v_club
    FOR UPDATE;

    IF v_balance IS NOT NULL THEN
      UPDATE public."Club_Finances"
      SET balance = v_balance - v_fee_charge
      WHERE club_name = v_club;
    END IF;

    -- Per-bid fee only (purchase amount lives on auction.winner_purchase_amount)
    UPDATE public.special_auction_bids
    SET fee_charged = v_row_fee
    WHERE auction_id = p_auction_id AND club_id = v_club;
  END LOOP;

  UPDATE public.special_auctions
  SET winning_club_id = v_win_club,
      winning_amount = v_win_amount,
      winner_discount_pct = coalesce(v_discount, 0),
      winner_purchase_amount = v_purchase,
      status = 'settled',
      updated_at = now()
  WHERE id = p_auction_id;

  SELECT * INTO v_auction FROM public.special_auctions WHERE id = p_auction_id;
  PERFORM public.special_auction_award_prize(v_auction, v_win_club, v_win_amount);
END;
$function$;

COMMENT ON FUNCTION public.special_auction_settle(bigint) IS
  'Settle special auction. Snap: charge winners 100% bid fees + discounted purchase; losers 25% bid fees. fee_charged is per-bid fee only.';
