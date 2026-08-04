-- Champ→SL expiry signing-on fee: 15% of player market value, paid to the player
-- (Championship buying-club debit only — not Central Bank / seller).
-- Safe re-run.

CREATE OR REPLACE FUNCTION public.contract_expiry_champ_sl_signing_fee_pct()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 15::numeric; $$;

COMMENT ON FUNCTION public.contract_expiry_champ_sl_signing_fee_pct() IS
  'Championship club signing-on fee when winning a Super League player on expiry — % of market value, paid to the player.';

-- Legacy flat helper (unused by resolve); kept for older callers.
CREATE OR REPLACE FUNCTION public.contract_expiry_champ_sl_signing_fee()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 0::numeric;
$$;

COMMENT ON FUNCTION public.contract_expiry_champ_sl_signing_fee() IS
  'Deprecated flat fee — resolve uses contract_expiry_champ_sl_signing_fee_pct() × market value.';

CREATE OR REPLACE FUNCTION public.contract_resolve_all_expiry_bids()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season       text;
  v_player       record;
  v_bid          record;
  v_resolved     int := 0;
  v_holder       text;
  v_mv           numeric;
  v_player_name  text;
  v_holder_tier  text;
  v_winner_tier  text;
  v_signing_fee  numeric;
  v_fee_pct      numeric := public.contract_expiry_champ_sl_signing_fee_pct();
  v_meta         jsonb;
BEGIN
  v_season := coalesce(public.current_gpsl_season_label(), 'unknown');

  FOR v_player IN
    SELECT p."Konami_ID"::text AS player_id
    FROM public."Players" p
    WHERE public.player_expiry_auction_applies(p."Konami_ID"::text)
  LOOP
    SELECT
      public.player_contracted_club_key(p."Contracted_Team"),
      greatest(coalesce(p.market_value::numeric, 0), 0),
      p."Name"
    INTO v_holder, v_mv, v_player_name
    FROM public."Players" p
    WHERE p."Konami_ID"::text = v_player.player_id
    FOR UPDATE;

    IF v_holder IS NULL THEN
      DELETE FROM public.contract_expiry_wage_bids b
      WHERE b.player_id = v_player.player_id
        AND b.season_label = v_season;
      CONTINUE;
    END IF;

    SELECT b.bidder_club_short_name, b.wage_offer
    INTO v_bid
    FROM public.contract_expiry_wage_bids b
    WHERE b.player_id = v_player.player_id
      AND b.season_label = v_season
    ORDER BY
      b.wage_offer DESC,
      CASE WHEN b.bidder_club_short_name = v_holder THEN 0 ELSE 1 END,
      b.created_at ASC
    LIMIT 1;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    v_meta := jsonb_build_object(
      'player_id', v_player.player_id,
      'player_name', v_player_name,
      'holding_club', v_holder,
      'winner_club', v_bid.bidder_club_short_name,
      'wage_offer', v_bid.wage_offer,
      'season_label', v_season,
      'source', 'contract_expiry'
    );

    -- Another club wins: MV compensation to holding club (+ Champ→SL player signing-on fee)
    IF v_bid.bidder_club_short_name IS DISTINCT FROM v_holder THEN
      IF v_mv > 0 THEN
        PERFORM public.post_club_ledger(
          v_bid.bidder_club_short_name,
          'transfer_purchase',
          -v_mv,
          'Expiry market MV compensation: ' || coalesce(v_player_name, v_player.player_id),
          v_meta || jsonb_build_object('market_value', v_mv),
          NULL,
          NULL,
          false,
          true
        );

        PERFORM public.post_club_ledger(
          v_holder,
          'transfer_sale',
          v_mv,
          'Expiry market MV compensation: ' || coalesce(v_player_name, v_player.player_id),
          v_meta || jsonb_build_object('market_value', v_mv),
          NULL,
          NULL,
          false,
          true
        );
      END IF;

      v_holder_tier := public.competition_club_division_tier(v_holder);
      v_winner_tier := public.competition_club_division_tier(v_bid.bidder_club_short_name);

      IF v_holder_tier = 'superleague' AND v_winner_tier = 'championship' THEN
        v_signing_fee := round(v_mv * v_fee_pct / 100.0);
        IF v_signing_fee > 0 THEN
          -- Signing-on fee to the player: debit buying club only
          PERFORM public.post_club_ledger(
            v_bid.bidder_club_short_name,
            'contract_expiry_champ_signing_fee',
            -v_signing_fee,
            'Championship signing-on fee to player ('
              || to_char(v_fee_pct, 'FM999')
              || '% MV, SL expiry): '
              || coalesce(v_player_name, v_player.player_id),
            v_meta || jsonb_build_object(
              'signing_fee', v_signing_fee,
              'signing_fee_pct', v_fee_pct,
              'signing_fee_to', 'player',
              'market_value', v_mv,
              'holder_tier', v_holder_tier,
              'winner_tier', v_winner_tier
            ),
            NULL,
            NULL,
            false,  -- not Central Bank
            true
          );
        END IF;
      END IF;

      INSERT INTO public."Transfer_History" (
        player_id,
        seller_club_id,
        buyer_club_id,
        fee,
        agent_fee,
        transfer_time,
        listing_id
      )
      VALUES (
        v_player.player_id,
        v_holder,
        v_bid.bidder_club_short_name,
        v_mv,
        0,
        now(),
        NULL
      );
    END IF;

    PERFORM public.player_assign_to_club(
      v_player.player_id,
      v_bid.bidder_club_short_name,
      v_bid.wage_offer
    );

    DELETE FROM public.contract_expiry_wage_bids b
    WHERE b.player_id = v_player.player_id
      AND b.season_label = v_season;

    v_resolved := v_resolved + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'season_label', v_season,
    'players_resolved', v_resolved
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.contract_expiry_champ_sl_signing_fee_pct() TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_expiry_champ_sl_signing_fee() TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_resolve_all_expiry_bids() TO authenticated;

NOTIFY pgrst, 'reload schema';
