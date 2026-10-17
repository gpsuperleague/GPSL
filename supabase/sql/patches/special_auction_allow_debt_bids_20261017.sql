-- Special auctions: allow bidding / fee charges while overdrawn.
-- Previously Blind Gauntlet Phase 2 blocked submit unless balance ≥ ₿3m.
-- Fees and winning bids still debit the club (can deepen debt).
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.special_auction_submit_gauntlet_bid(
  p_auction_id bigint,
  p_amount numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions%rowtype;
  v_club text := public.my_club_shortname();
  v_amount numeric;
  v_phase1 numeric;
  v_id bigint;
BEGIN
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked';
  END IF;

  PERFORM public.special_auction_gauntlet_tick(p_auction_id);

  SELECT * INTO a FROM public.special_auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND OR a.auction_type <> 'blind_gauntlet' THEN
    RAISE EXCEPTION 'Blind Gauntlet auction not found';
  END IF;

  IF a.status <> 'active' THEN
    RAISE EXCEPTION 'Auction is not open for bidding (status=%)', a.status;
  END IF;

  v_amount := public.round_bid_to_million(p_amount);
  IF v_amount IS NULL OR v_amount <= 0 THEN
    RAISE EXCEPTION 'Invalid bid amount';
  END IF;

  IF a.gauntlet_phase = 'phase1' THEN
    IF now() >= a.gauntlet_phase1_end_at THEN
      RAISE EXCEPTION 'Phase 1 has closed';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.special_auction_gauntlet_bids
      WHERE auction_id = p_auction_id AND club_id = v_club AND phase = 1
    ) THEN
      RAISE EXCEPTION 'You already submitted a Phase 1 bid';
    END IF;

    INSERT INTO public.special_auction_gauntlet_bids (
      auction_id, club_id, owner_id, phase, bid_amount
    )
    VALUES (p_auction_id, v_club, auth.uid(), 1, v_amount)
    RETURNING id INTO v_id;

    RETURN jsonb_build_object(
      'ok', true,
      'phase', 1,
      'bid_id', v_id,
      'bid_amount', v_amount,
      'note', 'Phase 1 bid locked as your Phase 2 minimum. Amount not charged yet.'
    );
  END IF;

  IF a.gauntlet_phase = 'phase2' THEN
    IF now() >= a.gauntlet_phase2_end_at THEN
      RAISE EXCEPTION 'Phase 2 has closed';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.special_auction_gauntlet_bids
      WHERE auction_id = p_auction_id AND club_id = v_club AND phase = 1 AND tier = 'top'
    ) THEN
      RAISE EXCEPTION 'Only Top tier advances to Phase 2';
    END IF;

    SELECT bid_amount INTO v_phase1
    FROM public.special_auction_gauntlet_bids
    WHERE auction_id = p_auction_id AND club_id = v_club AND phase = 1;

    IF v_phase1 IS NULL THEN
      RAISE EXCEPTION 'No Phase 1 bid found for your club';
    END IF;

    IF v_amount < v_phase1 THEN
      RAISE EXCEPTION 'Phase 2 bid must be ≥ your Phase 1 bid (₿%)',
        to_char(v_phase1, 'FM999,999,999,999');
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.special_auction_gauntlet_bids
      WHERE auction_id = p_auction_id AND club_id = v_club AND phase = 2
    ) THEN
      RAISE EXCEPTION 'You already submitted a Phase 2 bid';
    END IF;

    -- Charge ₿3m immediately (allowed while overdrawn — can deepen debt)
    PERFORM public.post_special_auction_ledger_line(
      v_club,
      'special_auction_fee',
      -3000000,
      format('Blind Gauntlet Phase 2 entry fee — %s', a.title),
      p_auction_id,
      true,
      jsonb_build_object(
        'ledger_role', format('gauntlet_p2_fee_%s', v_club),
        'phase', 2
      )
    );

    INSERT INTO public.special_auction_gauntlet_bids (
      auction_id, club_id, owner_id, phase, bid_amount, tier, phase2_fee
    )
    VALUES (p_auction_id, v_club, auth.uid(), 2, v_amount, 'top', 3000000)
    RETURNING id INTO v_id;

    RETURN jsonb_build_object(
      'ok', true,
      'phase', 2,
      'bid_id', v_id,
      'bid_amount', v_amount,
      'phase2_fee', 3000000,
      'note', 'Phase 2 entry fee ₿3,000,000 charged (even if overdrawn). Bid amount charged only if you win.'
    );
  END IF;

  RAISE EXCEPTION 'Bidding is closed during the % phase', coalesce(a.gauntlet_phase, 'unknown');
END;
$function$;

GRANT EXECUTE ON FUNCTION public.special_auction_submit_gauntlet_bid(bigint, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';
