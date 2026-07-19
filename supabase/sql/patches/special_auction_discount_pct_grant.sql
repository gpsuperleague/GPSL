-- =============================================================================
-- Special auction Discount prize → real fee_discount inventory
--
-- Adds prize_discount_pct (1–50). On settle/award, grants a Club Prizes
-- fee_discount token (same as Blind Gauntlet / challenge packs).
-- Label remains display text; auto-fills from % if blank.
--
-- Run after special_auction_prize_transfer_history.sql and
-- competition_challenge_prize_packs.sql (+ draft_token patch if used).
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.special_auctions
  ADD COLUMN IF NOT EXISTS prize_discount_pct int;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'special_auctions_prize_discount_pct_check'
  ) THEN
    ALTER TABLE public.special_auctions
      ADD CONSTRAINT special_auctions_prize_discount_pct_check
      CHECK (
        prize_discount_pct IS NULL
        OR (prize_discount_pct > 0 AND prize_discount_pct <= 50)
      );
  END IF;
END;
$$;

COMMENT ON COLUMN public.special_auctions.prize_discount_pct IS
  'Fee discount % granted to winner when prize_type = discount (Club Prizes inventory).';

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
      -- Fallback: parse leading digits from label (e.g. "25 %" / "10% off…")
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

    -- Idempotent: one grant per auction + club
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
  'Assign player/cash/discount prize; discount grants fee_discount inventory (1–50%).';

NOTIFY pgrst, 'reload schema';
