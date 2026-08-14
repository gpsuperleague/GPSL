-- =============================================================================
-- Special auction multi-prize packs (all types)
--
-- Reuses gauntlet_prize_pack for LUB / Snap / Blind Gauntlet:
--   medical_tokens[], fee_discounts[], appeal_cards, draft_tokens
-- Granted with the primary prize (player / cash / discount) on settle.
--
-- Run after special_auction_discount_pct_grant.sql and
-- special_auction_blind_gauntlet.sql (for column + grant helper).
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.special_auctions
  ADD COLUMN IF NOT EXISTS gauntlet_prize_pack jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.special_auctions.gauntlet_prize_pack IS
  'Optional bonus prizes for any auction type: medical_tokens[], fee_discounts[], appeal_cards, draft_tokens. Granted via special_auction_gauntlet_grant_pack.';

-- ---------------------------------------------------------------------------
-- Idempotent pack grant (Club Prizes inventory)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.special_auction_gauntlet_grant_pack(
  p_club text,
  p_pack jsonb,
  p_auction_id bigint,
  p_season_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_granted jsonb := '[]'::jsonb;
  v_med int;
  v_disc int;
  v_appeals int;
  v_drafts int;
  v_id bigint;
  v_i int;
  v_season bigint := p_season_id;
  v_meta jsonb;
BEGIN
  IF p_club IS NULL OR btrim(p_club) = '' THEN
    RETURN jsonb_build_object('granted', v_granted, 'note', 'no club');
  END IF;

  IF p_pack IS NULL OR p_pack = '{}'::jsonb THEN
    RETURN jsonb_build_object('granted', v_granted);
  END IF;

  -- Already granted for this auction (avoid double grant from settle + award_prize)
  IF EXISTS (
    SELECT 1
    FROM public.club_prize_inventory i
    WHERE i.club_short_name = p_club
      AND i.source = 'special_auction'
      AND coalesce((i.metadata->>'auction_id')::bigint, -1) = p_auction_id
      AND coalesce(i.metadata->>'pack_grant', '') = '1'
  ) THEN
    RETURN jsonb_build_object('granted', v_granted, 'already', true);
  END IF;

  IF v_season IS NULL THEN
    SELECT id INTO v_season
    FROM public.competition_seasons
    WHERE is_current = true
    ORDER BY id DESC
    LIMIT 1;
  END IF;

  IF to_regprocedure('public.prize_grant_inventory_item(text,text,int,text,bigint,text,jsonb)') IS NULL THEN
    RETURN jsonb_build_object('granted', v_granted, 'note', 'prize inventory not installed');
  END IF;

  v_meta := jsonb_build_object(
    'auction_id', p_auction_id,
    'pack_grant', '1'
  );

  FOR v_med IN
    SELECT jsonb_array_elements_text(coalesce(p_pack->'medical_tokens', '[]'::jsonb))::int
  LOOP
    IF v_med IN (2, 4, 6, 8, 10) THEN
      v_id := public.prize_grant_inventory_item(
        p_club, 'medical_token', v_med,
        'special_auction', v_season, NULL,
        v_meta || jsonb_build_object('label', format('Specialist consult −%s matches', v_med))
      );
      v_granted := v_granted || jsonb_build_array(
        jsonb_build_object('type', 'medical_token', 'param', v_med, 'id', v_id)
      );
    END IF;
  END LOOP;

  FOR v_disc IN
    SELECT jsonb_array_elements_text(coalesce(p_pack->'fee_discounts', '[]'::jsonb))::int
  LOOP
    IF v_disc > 0 AND v_disc <= 50 THEN
      v_id := public.prize_grant_inventory_item(
        p_club, 'fee_discount', v_disc,
        'special_auction', v_season, NULL,
        v_meta || jsonb_build_object('label', format('%s%% fee discount', v_disc))
      );
      v_granted := v_granted || jsonb_build_array(
        jsonb_build_object('type', 'fee_discount', 'param', v_disc, 'id', v_id)
      );
    END IF;
  END LOOP;

  v_appeals := coalesce((p_pack->>'appeal_cards')::int, 0);
  FOR v_i IN 1..greatest(v_appeals, 0) LOOP
    v_id := public.prize_grant_inventory_item(
      p_club, 'appeal_card', NULL,
      'special_auction', v_season, NULL,
      v_meta
    );
    v_granted := v_granted || jsonb_build_array(
      jsonb_build_object('type', 'appeal_card', 'id', v_id)
    );
  END LOOP;

  v_drafts := coalesce((p_pack->>'draft_tokens')::int, 0);
  FOR v_i IN 1..greatest(v_drafts, 0) LOOP
    BEGIN
      v_id := public.prize_grant_inventory_item(
        p_club, 'draft_token', NULL,
        'special_auction', v_season, NULL,
        v_meta
      );
      v_granted := v_granted || jsonb_build_array(
        jsonb_build_object('type', 'draft_token', 'id', v_id)
      );
    EXCEPTION WHEN others THEN
      NULL;
    END;
  END LOOP;

  RETURN jsonb_build_object('granted', v_granted);
END;
$function$;

COMMENT ON FUNCTION public.special_auction_gauntlet_grant_pack(text, jsonb, bigint, bigint) IS
  'Grant optional medical/appeal/discount/draft pack to a special-auction winner (any type). Idempotent per auction.';

-- ---------------------------------------------------------------------------
-- Award primary prize + optional pack
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.special_auction_award_prize(
  p_auction public.special_auctions,
  p_winner_club text,
  p_win_amount numeric DEFAULT 0
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
  v_discount_done boolean := false;
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

    -- Idempotent primary discount (do not RETURN — pack may still need granting)
    SELECT EXISTS (
      SELECT 1
      FROM public.club_prize_inventory i
      WHERE i.club_short_name = p_winner_club
        AND i.prize_type = 'fee_discount'
        AND i.source = 'special_auction'
        AND coalesce((i.metadata->>'auction_id')::bigint, -1) = p_auction.id
        AND coalesce(i.metadata->>'pack_grant', '') IS DISTINCT FROM '1'
    ) INTO v_discount_done;

    IF NOT v_discount_done THEN
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
  END IF;

  -- Bonus pack: specialist consults, appeal cards, extra discounts, draft tokens
  PERFORM public.special_auction_gauntlet_grant_pack(
    p_winner_club,
    coalesce(p_auction.gauntlet_prize_pack, '{}'::jsonb),
    p_auction.id,
    NULL
  );
END;
$function$;

COMMENT ON FUNCTION public.special_auction_award_prize(public.special_auctions, text, numeric) IS
  'Assign player/cash/discount prize plus optional gauntlet_prize_pack (medical/appeal/etc.).';

NOTIFY pgrst, 'reload schema';
