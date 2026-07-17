-- =============================================================================
-- Special auction player prizes → Transfer_History (Season Transfers)
--
-- Blind Gauntlet / Snap / LUB settle already debit the winning bid via
-- post_special_auction_ledger_line (special_auction_fee). They assign the
-- player via special_auction_award_prize → player_assign_to_club, but did
-- NOT insert Transfer_History — so Season Transfers missed the deal.
--
-- This patch:
--   1) Inserts Transfer_History on award (fee = winning bid; no second ledger)
--   2) Classifies the note as "Special auction"
--   3) Backfills missing rows for already-settled player-prize auctions
--
-- Safe re-run. Idempotent inserts.
-- =============================================================================

-- Inbox / news method label
CREATE OR REPLACE FUNCTION public.transfer_classify_method(
  p_seller_club text,
  p_buyer_club text,
  p_listing_id bigint,
  p_sale_note text,
  p_foreign_buyer_name text,
  p_method_override text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing_type text;
  v_note text := coalesce(btrim(p_sale_note), '');
  v_buyer text := btrim(coalesce(p_buyer_club, ''));
  v_seller text := btrim(coalesce(p_seller_club, ''));
BEGIN
  IF p_method_override IS NOT NULL AND btrim(p_method_override) <> '' THEN
    RETURN btrim(p_method_override);
  END IF;

  IF v_note = 'special_auction' OR v_note LIKE 'special_auction:%' THEN
    RETURN 'Special auction';
  END IF;

  IF p_listing_id IS NOT NULL THEN
    SELECT l.listing_type INTO v_listing_type
    FROM public."Player_Transfer_Listings" l
    WHERE l.id = p_listing_id;
  END IF;

  IF v_listing_type = 'draft' THEN
    RETURN 'Draft auction';
  END IF;

  IF v_note = 'squad_overflow' THEN
    IF v_buyer = 'FOREIGN' AND coalesce(btrim(p_foreign_buyer_name), '') <> '' THEN
      RETURN 'Foreign sale (squad over 28)';
    END IF;
    RETURN 'Squad release (market value, over 28)';
  END IF;

  IF v_buyer = 'FOREIGN' THEN
    IF coalesce(btrim(p_foreign_buyer_name), '') <> '' THEN
      RETURN 'Foreign sale — ' || btrim(p_foreign_buyer_name);
    END IF;
    RETURN 'Foreign sale';
  END IF;

  IF v_listing_type = 'direct' THEN
    RETURN 'Direct offer (transfer market)';
  END IF;

  IF v_seller <> '' AND v_buyer <> '' THEN
    RETURN 'Transfer list (auction)';
  END IF;

  IF v_seller = '' AND v_buyer <> '' THEN
    RETURN 'Draft auction signing';
  END IF;

  RETURN 'Player transfer';
END;
$function$;

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
      -- If already at winning club (re-award / repair), treat as free-agent signing
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

      -- Record as a transfer for Season Transfers / news.
      -- Do NOT call post_transfer_ledger_for_history — bid already charged as
      -- special_auction_fee on settle.
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
      -- Inbox / Discord come from Transfer_History insert trigger
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
  END IF;
END;
$function$;

COMMENT ON FUNCTION public.special_auction_award_prize(public.special_auctions, text, numeric) IS
  'Assign player/cash prize; player prizes also insert Transfer_History (winning bid fee, no second ledger debit).';

-- Backfill Declan Rice / any settled player-prize auctions missing history
CREATE OR REPLACE FUNCTION public.repair_special_auction_transfer_history()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  a public.special_auctions%rowtype;
  v_inserted int := 0;
  v_skipped int := 0;
  v_hist bigint;
  v_seller text;
  v_fee numeric;
BEGIN
  -- SQL Editor has no JWT (auth.uid() IS NULL); allow that or GPSL admin.
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR a IN
    SELECT *
    FROM public.special_auctions
    WHERE status = 'settled'
      AND prize_type = 'player'
      AND prize_player_id IS NOT NULL
      AND winning_club_id IS NOT NULL
    ORDER BY id
  LOOP
    SELECT h.id INTO v_hist
    FROM public."Transfer_History" h
    WHERE h.player_id::text = a.prize_player_id
      AND upper(btrim(h.buyer_club_id::text)) = upper(btrim(a.winning_club_id))
      AND coalesce(h.transfer_sale_note, '') = 'special_auction'
    ORDER BY h.id DESC
    LIMIT 1;

    IF v_hist IS NOT NULL THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    SELECT nullif(btrim(p."Contracted_Team"::text), '')
    INTO v_seller
    FROM public."Players" p
    WHERE p."Konami_ID"::text = a.prize_player_id;

    -- Player is already at winner; seller unknown for backfill → Free agent
    IF v_seller IS NOT NULL
       AND upper(btrim(v_seller)) = upper(btrim(a.winning_club_id)) THEN
      v_seller := NULL;
    END IF;

    v_fee := greatest(coalesce(a.winning_amount, 0), 0);

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
      a.prize_player_id,
      v_seller,
      a.winning_club_id,
      v_fee,
      0,
      coalesce(a.updated_at, a.end_time, now()),
      NULL,
      coalesce(nullif(btrim(a.title), ''), 'Special auction'),
      'special_auction'
    );

    v_inserted := v_inserted + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'inserted', v_inserted,
    'skipped_existing', v_skipped
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.repair_special_auction_transfer_history() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- After applying, run once as admin:
--   SELECT public.repair_special_auction_transfer_history();
