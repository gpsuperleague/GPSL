-- Blind Gauntlet: ensure player-prize winners get Keep / Take cash options.
-- Settle used to swallow award_prize errors, so winner_prize_pending stayed false.
-- Safe re-run.

-- ---------------------------------------------------------------------------
-- 1) Repair / open claim UI for settled player prizes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.special_auction_ensure_winner_prize_claim(
  p_auction_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  a public.special_auctions%rowtype;
  v_club text := public.my_club_shortname();
  v_is_admin boolean := public.is_gpsl_admin();
  v_award_err text := NULL;
  v_at_club text;
BEGIN
  SELECT * INTO a
  FROM public.special_auctions
  WHERE id = p_auction_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Auction not found';
  END IF;

  IF a.status IS DISTINCT FROM 'settled' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_settled');
  END IF;

  IF a.prize_type IS DISTINCT FROM 'player' OR a.prize_player_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_player_prize');
  END IF;

  IF a.winning_club_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_winner');
  END IF;

  IF NOT v_is_admin
     AND (
       v_club IS NULL
       OR upper(btrim(v_club)) IS DISTINCT FROM upper(btrim(a.winning_club_id))
     ) THEN
    RAISE EXCEPTION 'Only the winning club (or admin) can open prize claim';
  END IF;

  IF coalesce(a.winner_prize_resolved, false) THEN
    RETURN jsonb_build_object('ok', true, 'already_resolved', true);
  END IF;

  -- Mark claimable even if assign already happened / failed previously
  UPDATE public.special_auctions
  SET winner_prize_pending = true,
      winner_prize_resolved = false,
      updated_at = now()
  WHERE id = a.id
  RETURNING * INTO a;

  SELECT nullif(btrim(coalesce(p."Contracted_Team"::text, '')), '')
  INTO v_at_club
  FROM public."Players" p
  WHERE p."Konami_ID"::text = a.prize_player_id;

  IF v_at_club IS NULL
     OR upper(btrim(v_at_club)) IS DISTINCT FROM upper(btrim(a.winning_club_id)) THEN
    BEGIN
      PERFORM public.special_auction_award_prize(a, a.winning_club_id, a.winning_amount);
    EXCEPTION WHEN OTHERS THEN
      v_award_err := SQLERRM;
    END;
  END IF;

  -- Re-assert pending after award (award_prize also sets it on success)
  UPDATE public.special_auctions
  SET winner_prize_pending = true,
      winner_prize_resolved = false,
      updated_at = now()
  WHERE id = a.id
    AND NOT coalesce(winner_prize_resolved, false);

  RETURN jsonb_build_object(
    'ok', true,
    'auction_id', a.id,
    'winning_club_id', a.winning_club_id,
    'prize_player_id', a.prize_player_id,
    'winner_prize_pending', true,
    'award_error', v_award_err
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.special_auction_ensure_winner_prize_claim(bigint)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 2) Gauntlet settle: always open claim for player prizes; surface award errors
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.special_auction_gauntlet_settle(p_auction_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions%rowtype;
  v_win record;
  v_pack jsonb;
  v_body text;
  v_award_err text := NULL;
BEGIN
  SELECT * INTO a FROM public.special_auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND OR a.auction_type <> 'blind_gauntlet' THEN
    RAISE EXCEPTION 'Blind Gauntlet auction not found';
  END IF;

  IF a.status = 'settled' THEN
    RETURN jsonb_build_object('ok', true, 'already_settled', true);
  END IF;

  SELECT b.* INTO v_win
  FROM public.special_auction_gauntlet_bids b
  WHERE b.auction_id = p_auction_id AND b.phase = 2
  ORDER BY b.bid_amount DESC, b.bid_time ASC, b.id ASC
  LIMIT 1;

  IF NOT FOUND THEN
    UPDATE public.special_auctions
    SET status = 'settled',
        gauntlet_phase = 'failed',
        updated_at = now()
    WHERE id = p_auction_id;

    BEGIN
      PERFORM public.owner_inbox_notify_all_clubs(
        'special_auction_scheduled',
        format('Blind Gauntlet failed — %s', a.title),
        'No Phase 2 bids were submitted. Auction ended with no winner.',
        'special_auction_gauntlet.html?id=' || p_auction_id::text,
        format('gauntlet_failed:%s', p_auction_id),
        NULL
      );
    EXCEPTION WHEN others THEN
      NULL;
    END;

    RETURN jsonb_build_object('ok', true, 'failed', true, 'reason', 'no_phase2_bids');
  END IF;

  UPDATE public.special_auction_gauntlet_bids
  SET is_winner = (id = v_win.id)
  WHERE auction_id = p_auction_id AND phase = 2;

  PERFORM public.post_special_auction_ledger_line(
    v_win.club_id,
    'special_auction_fee',
    -abs(v_win.bid_amount),
    format('Blind Gauntlet winning bid — %s', a.title),
    p_auction_id,
    true,
    jsonb_build_object(
      'ledger_role', 'gauntlet_win_bid',
      'phase', 2,
      'bid_amount', v_win.bid_amount
    )
  );

  UPDATE public.special_auctions
  SET
    status = 'settled',
    gauntlet_phase = 'complete',
    winning_club_id = v_win.club_id,
    winning_amount = v_win.bid_amount,
    winner_prize_pending = CASE
      WHEN prize_type = 'player' AND prize_player_id IS NOT NULL THEN true
      ELSE winner_prize_pending
    END,
    winner_prize_resolved = CASE
      WHEN prize_type = 'player' AND prize_player_id IS NOT NULL THEN false
      ELSE winner_prize_resolved
    END,
    updated_at = now()
  WHERE id = p_auction_id
  RETURNING * INTO a;

  BEGIN
    PERFORM public.special_auction_award_prize(a, v_win.club_id, v_win.bid_amount);
  EXCEPTION WHEN others THEN
    v_award_err := SQLERRM;
    -- Keep claim UI open for player prizes even if assign failed
    IF a.prize_type = 'player' AND a.prize_player_id IS NOT NULL THEN
      UPDATE public.special_auctions
      SET winner_prize_pending = true,
          winner_prize_resolved = false,
          updated_at = now()
      WHERE id = a.id;
    END IF;
  END;

  v_pack := public.special_auction_gauntlet_grant_pack(
    v_win.club_id,
    coalesce(a.gauntlet_prize_pack, '{}'::jsonb),
    p_auction_id,
    NULL
  );

  SELECT string_agg(
    format('%s: ₿%s%s', b.club_id, to_char(b.bid_amount, 'FM999,999,999,999'),
      CASE WHEN b.is_winner THEN ' ★' ELSE '' END),
    E'\n' ORDER BY b.bid_amount DESC, b.bid_time ASC
  )
  INTO v_body
  FROM public.special_auction_gauntlet_bids b
  WHERE b.auction_id = p_auction_id AND b.phase = 2;

  v_body := format(
    E'%s won Blind Gauntlet with ₿%s.\n\nPhase 2 bids:\n%s\n\nPhase 1 bids:\n%s\n\nIf the prize is a player, open Blind Gauntlet to Keep or take cash (MV).',
    v_win.club_id,
    to_char(v_win.bid_amount, 'FM999,999,999,999'),
    coalesce(v_body, '—'),
    coalesce((
      SELECT string_agg(
        format('%s: ₿%s (%s)', b.club_id, to_char(b.bid_amount, 'FM999,999,999,999'), coalesce(b.tier, '?')),
        E'\n' ORDER BY b.bid_amount DESC, b.bid_time ASC
      )
      FROM public.special_auction_gauntlet_bids b
      WHERE b.auction_id = p_auction_id AND b.phase = 1
    ), '—')
  );

  BEGIN
    PERFORM public.owner_inbox_notify_all_clubs(
      'special_auction_scheduled',
      format('Blind Gauntlet result — %s', a.title),
      v_body,
      'special_auction_gauntlet.html?id=' || p_auction_id::text,
      format('gauntlet_result:%s', p_auction_id),
      NULL
    );
  EXCEPTION WHEN others THEN
    NULL;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'winning_club_id', v_win.club_id,
    'winning_amount', v_win.bid_amount,
    'pack', v_pack,
    'winner_prize_pending', coalesce(a.prize_type = 'player' AND a.prize_player_id IS NOT NULL, false),
    'award_error', v_award_err
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.special_auction_gauntlet_settle(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
