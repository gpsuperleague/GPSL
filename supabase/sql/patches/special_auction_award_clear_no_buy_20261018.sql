-- =============================================================================
-- Special auction player prize: allow award despite no-buy / paid-up lock
--
-- Symptom (Mystery Snap / Blind Gauntlet settle):
--   Player is unavailable until Next season — contracted to Young Boys
--   special_auction_settle → 400
--
-- Cause: auction-exclusion prizes are free agents reserved for special auction,
--   but voluntary release / foreign / paid-up locks still fire
--   assert_player_available_for_signing inside player_assign_to_club.
--   Draft stays blocked; special auction is the intentional exception.
--
-- Fix: clear foreign_contract_* lock before assign on player prize award.
-- Based on special_auction_discount_pct_grant.sql award_prize body.
-- Safe re-run. Then re-try settle on the stuck auction.
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
  v_seller text;
  v_hist bigint;
  v_note text;
  v_fee numeric := greatest(coalesce(p_win_amount, 0), 0);
  v_pct int;
  v_season bigint;
  v_inv_id bigint;
  v_label text;
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
      v_seller := nullif(btrim(coalesce(v_player."Contracted_Team"::text, '')), '');
      IF v_seller IS NOT NULL
         AND upper(btrim(v_seller)) = upper(btrim(p_winner_club)) THEN
        v_seller := NULL;
      END IF;

      -- Special-auction prizes may carry a no-buy / paid-up lock from the
      -- releasing club (draft stays blocked). Clear so assign can complete.
      IF to_regprocedure('public.player_clear_foreign_contract_lock(text)') IS NOT NULL THEN
        PERFORM public.player_clear_foreign_contract_lock(p_auction.prize_player_id);
      ELSE
        UPDATE public."Players"
        SET
          foreign_contract_club = NULL,
          foreign_contract_sold_season_id = NULL,
          foreign_contract_unlock_season_label = NULL,
          foreign_contract_lock_kind = NULL
        WHERE "Konami_ID"::text = p_auction.prize_player_id;
      END IF;

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
      v_note := 'special_auction';

      SELECT h.id INTO v_hist
      FROM public."Transfer_History" h
      WHERE h.player_id::text = p_auction.prize_player_id
        AND upper(btrim(h.buyer_club_id::text)) = upper(btrim(p_winner_club))
        AND coalesce(h.transfer_sale_note, '') = v_note
      ORDER BY h.id DESC
      LIMIT 1;

      IF v_hist IS NULL THEN
        INSERT INTO public."Transfer_History" (
          player_id,
          seller_club_id,
          buyer_club_id,
          fee,
          agent_fee,
          transfer_time,
          listing_id,
          foreign_buyer_name,
          transfer_sale_note
        )
        VALUES (
          p_auction.prize_player_id,
          v_seller,
          p_winner_club,
          v_fee,
          0,
          coalesce(p_auction.updated_at, now()),
          NULL,
          v_title,
          v_note
        )
        RETURNING id INTO v_hist;
      END IF;
    END IF;

  ELSIF p_auction.prize_type = 'cash' AND coalesce(p_auction.prize_cash_amount, 0) > 0 THEN
    UPDATE public."Club_Finances"
    SET balance = balance + p_auction.prize_cash_amount
    WHERE club_name = p_winner_club;

    IF to_regprocedure(
      'public.post_special_auction_ledger_line(text,text,numeric,text,bigint,boolean,jsonb)'
    ) IS NOT NULL THEN
      PERFORM public.post_special_auction_ledger_line(
        p_winner_club,
        'special_auction_prize',
        abs(p_auction.prize_cash_amount),
        format('Special auction cash prize — %s', coalesce(p_auction.title, 'Auction #' || p_auction.id)),
        p_auction.id,
        false,
        jsonb_build_object('ledger_role', 'cash_prize', 'prize_type', 'cash')
      );
    END IF;

  ELSIF p_auction.prize_type = 'discount' THEN
    v_pct := p_auction.prize_discount_pct;
    IF v_pct IS NULL OR v_pct <= 0 THEN
      BEGIN
        v_pct := nullif(
          substring(coalesce(p_auction.prize_discount_label, '') from '([0-9]{1,2})'),
          ''
        )::int;
      EXCEPTION WHEN OTHERS THEN
        v_pct := NULL;
      END;
    END IF;

    IF v_pct IS NULL OR v_pct <= 0 OR v_pct > 50 THEN
      RAISE EXCEPTION
        'Discount prize needs prize_discount_pct between 1 and 50 (got %)',
        coalesce(v_pct::text, 'null');
    END IF;

    v_label := nullif(btrim(coalesce(p_auction.prize_discount_label, '')), '');
    IF v_label IS NULL THEN
      v_label := format('%s%% fee discount', v_pct);
      UPDATE public.special_auctions
      SET prize_discount_label = v_label,
          prize_discount_pct = v_pct,
          updated_at = now()
      WHERE id = p_auction.id
        AND (prize_discount_label IS NULL OR btrim(prize_discount_label) = '');
    ELSIF p_auction.prize_discount_pct IS NULL THEN
      UPDATE public.special_auctions
      SET prize_discount_pct = v_pct,
          updated_at = now()
      WHERE id = p_auction.id;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.club_prize_inventory i
      WHERE i.club_short_name = p_winner_club
        AND i.prize_type = 'fee_discount'
        AND i.source = 'special_auction'
        AND coalesce((i.metadata->>'auction_id')::bigint, -1) = p_auction.id
    ) THEN
      RETURN;
    END IF;

    IF to_regprocedure(
      'public.prize_grant_inventory_item(text,text,int,text,bigint,text,jsonb)'
    ) IS NULL THEN
      RAISE EXCEPTION
        'prize_grant_inventory_item missing — run competition_challenge_prize_packs.sql';
    END IF;

    SELECT id INTO v_season
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;

    v_inv_id := public.prize_grant_inventory_item(
      p_winner_club,
      'fee_discount',
      v_pct,
      'special_auction',
      v_season,
      NULL,
      jsonb_build_object(
        'auction_id', p_auction.id,
        'auction_title', coalesce(p_auction.title, ''),
        'label', coalesce(v_label, format('%s%% fee discount', v_pct))
      )
    );

    IF v_inv_id IS NULL THEN
      RAISE EXCEPTION 'Failed to grant fee_discount inventory for auction %', p_auction.id;
    END IF;
  END IF;
END;
$function$;

COMMENT ON FUNCTION public.special_auction_award_prize(public.special_auctions, text, numeric) IS
  'Assign player/cash/discount prize; clears no-buy/paid-up lock before player assign (draft stays blocked until award).';

NOTIFY pgrst, 'reload schema';
