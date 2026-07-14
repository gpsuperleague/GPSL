-- =============================================================================
-- Fix special_auction_settle — player_assign_to_club(text, text) not unique
--
-- Cause: 3-arg and 4-arg overloads both accept a 2-arg call (DEFAULT args).
-- Fix: call the canonical 4-arg form explicitly (same as draft settlement).
--
-- Run once in Supabase SQL Editor. Safe re-run. Then Settle again.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.special_auction_award_prize(
  p_auction public.special_auctions,
  p_winner_club text,
  p_win_amount numeric
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player public."Players"%rowtype;
  v_title text;
BEGIN
  IF p_winner_club IS NULL THEN
    RETURN;
  END IF;

  IF p_auction.prize_type = 'player' AND p_auction.prize_player_id IS NOT NULL THEN
    SELECT * INTO v_player
    FROM public."Players"
    WHERE "Konami_ID"::text = p_auction.prize_player_id
    FOR UPDATE;

    IF FOUND THEN
      -- Explicit 4-arg call — avoids overload ambiguity with (text, text)
      PERFORM public.player_assign_to_club(
        p_auction.prize_player_id,
        p_winner_club,
        NULL::numeric,
        false
      );

      DELETE FROM public.auction_exclusion_players
      WHERE player_id = p_auction.prize_player_id;

      UPDATE public.special_auctions
      SET winner_prize_pending = true,
          winner_prize_resolved = false,
          updated_at = now()
      WHERE id = p_auction.id;

      v_title := coalesce(nullif(btrim(p_auction.title), ''), 'Special auction');

      BEGIN
        PERFORM public.transfer_inbox_notify_deal(
          p_auction.prize_player_id,
          v_player."Name",
          NULL,
          p_winner_club,
          coalesce(p_win_amount, 0),
          0,
          NULL,
          NULL,
          NULL,
          NULL,
          'Special auction',
          'Auction: ' || v_title || E'\nWinning bid: ₿' ||
            to_char(coalesce(p_win_amount, 0), 'FM999,999,999,999')
        );
      EXCEPTION WHEN undefined_function THEN
        NULL;
      WHEN OTHERS THEN
        RAISE WARNING 'special_auction inbox notify failed: %', SQLERRM;
      END;
    END IF;

  ELSIF p_auction.prize_type = 'cash' AND coalesce(p_auction.prize_cash_amount, 0) > 0 THEN
    UPDATE public."Club_Finances"
    SET balance = balance + p_auction.prize_cash_amount
    WHERE club_name = p_winner_club;
  END IF;
END;
$function$;

COMMENT ON FUNCTION public.special_auction_award_prize(public.special_auctions, text, numeric) IS
  'Assign player prize (or cash). Uses player_assign_to_club(text,text,numeric,boolean) to avoid overload ambiguity.';
