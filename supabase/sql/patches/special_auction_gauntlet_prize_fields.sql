-- Hotfix: expose known_player_id / discount label on gauntlet owner state
-- Safe re-run (replaces function body from special_auction_blind_gauntlet.sql)

CREATE OR REPLACE FUNCTION public.special_auction_gauntlet_owner_state(p_auction_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions%rowtype;
  v_club text := public.my_club_shortname();
  v_p1 public.special_auction_gauntlet_bids%rowtype;
  v_p2 public.special_auction_gauntlet_bids%rowtype;
  v_phase2_bids jsonb := '[]'::jsonb;
  v_phase1_bids jsonb := '[]'::jsonb;
  v_reveal boolean := false;
BEGIN
  PERFORM public.special_auction_gauntlet_tick(p_auction_id);

  SELECT * INTO a FROM public.special_auctions WHERE id = p_auction_id;
  IF NOT FOUND OR a.auction_type <> 'blind_gauntlet' THEN
    RAISE EXCEPTION 'Blind Gauntlet auction not found';
  END IF;

  SELECT * INTO v_p1
  FROM public.special_auction_gauntlet_bids
  WHERE auction_id = p_auction_id AND club_id = v_club AND phase = 1;

  SELECT * INTO v_p2
  FROM public.special_auction_gauntlet_bids
  WHERE auction_id = p_auction_id AND club_id = v_club AND phase = 2;

  v_reveal := a.gauntlet_phase IN ('complete', 'failed') OR a.status = 'settled';

  IF v_reveal THEN
    SELECT coalesce(jsonb_agg(
      jsonb_build_object(
        'club_id', b.club_id,
        'bid_amount', b.bid_amount,
        'bid_time', b.bid_time,
        'is_winner', b.is_winner
      )
      ORDER BY b.bid_amount DESC, b.bid_time ASC
    ), '[]'::jsonb)
    INTO v_phase2_bids
    FROM public.special_auction_gauntlet_bids b
    WHERE b.auction_id = p_auction_id AND b.phase = 2;

    SELECT coalesce(jsonb_agg(
      jsonb_build_object(
        'club_id', b.club_id,
        'bid_amount', b.bid_amount,
        'bid_time', b.bid_time,
        'tier', b.tier,
        'phase1_fee', b.phase1_fee
      )
      ORDER BY b.bid_amount DESC, b.bid_time ASC
    ), '[]'::jsonb)
    INTO v_phase1_bids
    FROM public.special_auction_gauntlet_bids b
    WHERE b.auction_id = p_auction_id AND b.phase = 1;
  END IF;

  RETURN jsonb_build_object(
    'auction_id', a.id,
    'title', a.title,
    'status', a.status,
    'gauntlet_phase', a.gauntlet_phase,
    'start_time', a.start_time,
    'phase1_end_at', a.gauntlet_phase1_end_at,
    'reveal_end_at', a.gauntlet_reveal_end_at,
    'phase2_end_at', a.gauntlet_phase2_end_at,
    'prize_type', a.prize_type,
    'prize_player_id', a.prize_player_id,
    'known_player_id', a.known_player_id,
    'prize_cash_amount', a.prize_cash_amount,
    'prize_discount_label', a.prize_discount_label,
    'player_mode', a.player_mode,
    'gauntlet_prize_pack', a.gauntlet_prize_pack,
    'winning_club_id', a.winning_club_id,
    'winning_amount', a.winning_amount,
    'my_club', v_club,
    'my_phase1', CASE WHEN v_p1.id IS NULL THEN NULL ELSE jsonb_build_object(
      'bid_amount', v_p1.bid_amount,
      'tier', v_p1.tier,
      'phase1_fee', v_p1.phase1_fee,
      'bid_time', v_p1.bid_time
    ) END,
    'my_phase2', CASE WHEN v_p2.id IS NULL THEN NULL ELSE jsonb_build_object(
      'bid_amount', v_p2.bid_amount,
      'phase2_fee', v_p2.phase2_fee,
      'is_winner', v_p2.is_winner,
      'bid_time', v_p2.bid_time
    ) END,
    'can_bid_phase1', a.status = 'active' AND a.gauntlet_phase = 'phase1'
      AND now() < a.gauntlet_phase1_end_at AND v_p1.id IS NULL,
    'can_bid_phase2', a.status = 'active' AND a.gauntlet_phase = 'phase2'
      AND now() < a.gauntlet_phase2_end_at
      AND v_p1.tier = 'top' AND v_p2.id IS NULL,
    'phase2_min', v_p1.bid_amount,
    'revealed', v_reveal,
    'phase1_bids', v_phase1_bids,
    'phase2_bids', v_phase2_bids
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.special_auction_gauntlet_owner_state(bigint) TO authenticated;
NOTIFY pgrst, 'reload schema';
