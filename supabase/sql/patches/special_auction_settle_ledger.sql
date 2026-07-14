-- =============================================================================
-- Special auction settle → finance ledger (Purchases → Special auction fee)
--
-- Settle currently only adjusted Club_Finances.balance, so Accounts/Finances
-- showed no named line. This restore posts special_auction_fee ledger rows
-- (and applies balance via post_club_ledger).
--
-- Snap:
--   losers  → one line: 25% of (bid_count × snap_bid_fee)
--   winner  → bid-fees line (100%) + purchase line (discounted winning bid)
-- LUB:
--   winner  → one line for winning bid amount
--
-- Also: admin_special_auction_backfill_fee_ledger(id) posts ledger-only
-- (no second balance hit) for auctions already settled before this patch.
--
-- Run once. Safe re-run.
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
  v_unit_fee numeric;
  v_row_fee numeric;
  v_title text;
  v_has_ledger boolean;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_auction FROM public.special_auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Auction not found'; END IF;

  v_title := coalesce(nullif(btrim(v_auction.title), ''), 'Auction #' || v_auction.id);
  v_has_ledger := to_regprocedure(
    'public.post_special_auction_ledger_line(text,text,numeric,text,bigint,boolean,jsonb)'
  ) IS NOT NULL;

  IF v_auction.auction_type = 'lowest_unique' THEN
    IF v_auction.status = 'settled' THEN
      RAISE EXCEPTION 'Auction already settled — use admin_special_auction_backfill_fee_ledger(%) for ledger-only backfill',
        p_auction_id;
    END IF;
    IF v_auction.status = 'active' THEN
      PERFORM public.special_auction_reveal_lowest_unique(p_auction_id);
      SELECT * INTO v_auction FROM public.special_auctions WHERE id = p_auction_id;
    END IF;
    IF v_auction.status <> 'revealed' THEN
      RAISE EXCEPTION 'Reveal the lowest unique auction first';
    END IF;
    v_win_club := v_auction.winning_club_id;
    v_win_amount := v_auction.winning_amount;

    IF v_win_club IS NULL THEN
      UPDATE public.special_auctions SET status = 'settled', updated_at = now() WHERE id = p_auction_id;
      RETURN;
    END IF;

    IF v_has_ledger THEN
      PERFORM public.post_special_auction_ledger_line(
        v_win_club,
        'special_auction_fee',
        -abs(coalesce(v_win_amount, 0)),
        format('Lowest unique bid — %s', v_title),
        p_auction_id,
        true,
        jsonb_build_object(
          'ledger_role', 'lub_win',
          'auction_type', 'lowest_unique',
          'winning_amount', v_win_amount
        )
      );
    ELSE
      UPDATE public."Club_Finances"
      SET balance = coalesce(balance, 0) - coalesce(v_win_amount, 0)
      WHERE club_name = v_win_club;
    END IF;

    UPDATE public.special_auction_bids
    SET fee_charged = v_win_amount, is_winner = (club_id = v_win_club)
    WHERE auction_id = p_auction_id;

    PERFORM public.special_auction_award_prize(v_auction, v_win_club, v_win_amount);
    UPDATE public.special_auctions SET status = 'settled', updated_at = now() WHERE id = p_auction_id;
    RETURN;
  END IF;

  IF v_auction.auction_type <> 'snap' THEN
    RAISE EXCEPTION 'Unknown auction type';
  END IF;

  -- Already settled: do not charge again
  IF v_auction.status = 'settled' THEN
    RAISE EXCEPTION 'Auction already settled — use admin_special_auction_backfill_fee_ledger(%) for ledger-only backfill',
      p_auction_id;
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
      v_row_fee := v_unit_fee;

      IF v_has_ledger THEN
        IF v_fee_total > 0 THEN
          PERFORM public.post_special_auction_ledger_line(
            v_club,
            'special_auction_fee',
            -abs(v_fee_total),
            format(
              'Snap bid fees (%s×₿%s) — %s',
              v_bid_count,
              to_char(v_unit_fee, 'FM999,999,999,999'),
              v_title
            ),
            p_auction_id,
            true,
            jsonb_build_object(
              'ledger_role', 'snap_bid_fees',
              'auction_type', 'snap',
              'bid_count', v_bid_count,
              'unit_fee', v_unit_fee,
              'is_winner', true
            )
          );
        END IF;
        IF coalesce(v_purchase, 0) > 0 THEN
          PERFORM public.post_special_auction_ledger_line(
            v_club,
            'special_auction_fee',
            -abs(v_purchase),
            format(
              'Snap winning bid (after %s%% discount) — %s',
              to_char(coalesce(v_discount, 0), 'FM999'),
              v_title
            ),
            p_auction_id,
            true,
            jsonb_build_object(
              'ledger_role', 'snap_purchase',
              'auction_type', 'snap',
              'winning_amount', v_win_amount,
              'discount_pct', v_discount,
              'purchase_amount', v_purchase,
              'is_winner', true
            )
          );
        END IF;
      ELSE
        UPDATE public."Club_Finances"
        SET balance = coalesce(balance, 0) - (v_fee_total + coalesce(v_purchase, 0))
        WHERE club_name = v_club;
      END IF;
    ELSE
      v_row_fee := round(v_unit_fee * 0.25);
      v_fee_total := round(v_fee_total * 0.25);

      IF v_has_ledger THEN
        IF v_fee_total > 0 THEN
          PERFORM public.post_special_auction_ledger_line(
            v_club,
            'special_auction_fee',
            -abs(v_fee_total),
            format(
              'Snap bid fees (25%% of %s bid(s)) — %s',
              v_bid_count,
              v_title
            ),
            p_auction_id,
            true,
            jsonb_build_object(
              'ledger_role', 'snap_bid_fees',
              'auction_type', 'snap',
              'bid_count', v_bid_count,
              'unit_fee', v_unit_fee,
              'is_winner', false
            )
          );
        END IF;
      ELSE
        UPDATE public."Club_Finances"
        SET balance = coalesce(balance, 0) - v_fee_total
        WHERE club_name = v_club;
      END IF;
    END IF;

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

-- ---------------------------------------------------------------------------
-- Ledger-only backfill for auctions already settled (balance already moved)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_special_auction_backfill_fee_ledger(
  p_auction_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_auction public.special_auctions%rowtype;
  v_title text;
  v_unit_fee numeric;
  v_club text;
  v_bid_count int;
  v_fee_total numeric;
  v_purchase numeric;
  v_posted int := 0;
  v_id bigint;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_auction FROM public.special_auctions WHERE id = p_auction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Auction not found'; END IF;
  IF v_auction.status <> 'settled' THEN
    RAISE EXCEPTION 'Auction is not settled';
  END IF;
  IF to_regprocedure(
    'public.post_special_auction_ledger_line(text,text,numeric,text,bigint,boolean,jsonb)'
  ) IS NULL THEN
    RAISE EXCEPTION 'post_special_auction_ledger_line not installed';
  END IF;

  v_title := coalesce(nullif(btrim(v_auction.title), ''), 'Auction #' || v_auction.id);
  v_unit_fee := coalesce(nullif(v_auction.snap_bid_fee, 0), 300000);
  v_purchase := coalesce(v_auction.winner_purchase_amount, 0);

  IF v_auction.auction_type = 'lowest_unique' THEN
    IF v_auction.winning_club_id IS NOT NULL AND coalesce(v_auction.winning_amount, 0) > 0 THEN
      v_id := public.post_special_auction_ledger_line(
        v_auction.winning_club_id,
        'special_auction_fee',
        -abs(v_auction.winning_amount),
        format('Lowest unique bid — %s (backfill)', v_title),
        p_auction_id,
        false,
        jsonb_build_object('ledger_role', 'lub_win', 'auction_type', 'lowest_unique', 'backfill', true)
      );
      IF v_id IS NOT NULL THEN v_posted := v_posted + 1; END IF;
    END IF;
  ELSIF v_auction.auction_type = 'snap' THEN
    FOR v_club, v_bid_count IN
      SELECT b.club_id, count(*)::int
      FROM public.special_auction_bids b
      WHERE b.auction_id = p_auction_id
      GROUP BY b.club_id
    LOOP
      IF v_club = v_auction.winning_club_id THEN
        v_fee_total := v_bid_count * v_unit_fee;
        IF v_fee_total > 0 THEN
          v_id := public.post_special_auction_ledger_line(
            v_club,
            'special_auction_fee',
            -abs(v_fee_total),
            format('Snap bid fees (%s×) — %s (backfill)', v_bid_count, v_title),
            p_auction_id,
            false,
            jsonb_build_object(
              'ledger_role', 'snap_bid_fees',
              'auction_type', 'snap',
              'bid_count', v_bid_count,
              'is_winner', true,
              'backfill', true
            )
          );
          IF v_id IS NOT NULL THEN v_posted := v_posted + 1; END IF;
        END IF;
        IF v_purchase > 0 THEN
          v_id := public.post_special_auction_ledger_line(
            v_club,
            'special_auction_fee',
            -abs(v_purchase),
            format('Snap winning bid (discounted) — %s (backfill)', v_title),
            p_auction_id,
            false,
            jsonb_build_object(
              'ledger_role', 'snap_purchase',
              'auction_type', 'snap',
              'purchase_amount', v_purchase,
              'discount_pct', v_auction.winner_discount_pct,
              'is_winner', true,
              'backfill', true
            )
          );
          IF v_id IS NOT NULL THEN v_posted := v_posted + 1; END IF;
        END IF;
      ELSE
        v_fee_total := round(v_bid_count * v_unit_fee * 0.25);
        IF v_fee_total > 0 THEN
          v_id := public.post_special_auction_ledger_line(
            v_club,
            'special_auction_fee',
            -abs(v_fee_total),
            format('Snap bid fees (25%%) — %s (backfill)', v_title),
            p_auction_id,
            false,
            jsonb_build_object(
              'ledger_role', 'snap_bid_fees',
              'auction_type', 'snap',
              'bid_count', v_bid_count,
              'is_winner', false,
              'backfill', true
            )
          );
          IF v_id IS NOT NULL THEN v_posted := v_posted + 1; END IF;
        END IF;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'auction_id', p_auction_id,
    'lines_posted', v_posted
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.special_auction_settle(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_special_auction_backfill_fee_ledger(bigint) TO authenticated;

COMMENT ON FUNCTION public.special_auction_settle(bigint) IS
  'Settle special auction with special_auction_fee ledger lines (Finances → Purchases).';
COMMENT ON FUNCTION public.admin_special_auction_backfill_fee_ledger(bigint) IS
  'Post missing special_auction_fee ledger lines for an already-settled auction without changing balances again.';

NOTIFY pgrst, 'reload schema';
