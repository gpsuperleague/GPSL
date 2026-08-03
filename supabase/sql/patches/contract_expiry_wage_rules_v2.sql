-- =============================================================================
-- Expiring-contract wage bids — rules v2
--
-- • All wage offers must be strictly > current contract wage
-- • Offers must be in ₿250,000 increments
-- • Highest bid wins at season rollover (tie → holding club)
-- • Other club wins → pay market value compensation to holding club
-- • Championship club signing a Super League player → ₿10m one-off to Central Bank
--   (separate from wage; only if Champ club wins the player)
--
-- Safe re-run. Requires player_contracts_phase3_expiry.sql + player_wage_settings.sql
-- + central_bank_phase1.sql (post_club_ledger).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.contract_expiry_wage_bid_step()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 250000::numeric; $$;

CREATE OR REPLACE FUNCTION public.contract_expiry_champ_sl_signing_fee()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$ SELECT 10000000::numeric; $$;

COMMENT ON FUNCTION public.contract_expiry_wage_bid_step() IS
  'Hidden expiry wage offers must be multiples of this amount (₿250,000).';

COMMENT ON FUNCTION public.contract_expiry_champ_sl_signing_fee() IS
  'One-off fee to Central Bank when a Championship club wins an SL player on expiry.';

-- Minimum valid offer: next ₿250k step strictly above current wage
CREATE OR REPLACE FUNCTION public.contract_expiry_min_wage_offer(p_current_wage numeric)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_step numeric := public.contract_expiry_wage_bid_step();
  v_cur  numeric := greatest(coalesce(p_current_wage, 0), 0);
BEGIN
  RETURN (floor(v_cur / v_step) * v_step) + v_step;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Submit / update hidden wage bid
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.contract_submit_expiry_wage_bid(
  p_player_id text,
  p_wage_offer numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club      text;
  v_pid       text := btrim(p_player_id);
  v_wage      numeric;
  v_season    text;
  v_holder    text;
  v_current   numeric;
  v_min_offer numeric;
  v_step      numeric := public.contract_expiry_wage_bid_step();
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF NOT public.player_expiry_auction_applies(v_pid) THEN
    RAISE EXCEPTION
      'This player is not on the expiring-contract market (final year, standard player only)';
  END IF;

  v_wage := round(coalesce(p_wage_offer, 0), 0);
  IF v_wage <= 0 THEN
    RAISE EXCEPTION 'Wage bid must be greater than zero';
  END IF;

  IF mod(v_wage, v_step) <> 0 THEN
    RAISE EXCEPTION
      'Wage offers must be in ₿% increments',
      to_char(v_step, 'FM999,999,999');
  END IF;

  SELECT public.player_contracted_club_key(p."Contracted_Team"),
         p.contract_wage
  INTO v_holder, v_current
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid;

  v_min_offer := public.contract_expiry_min_wage_offer(v_current);

  IF v_wage < v_min_offer THEN
    RAISE EXCEPTION
      'Wage offer must be at least ₿% (higher than current wage ₿%, in ₿% steps)',
      to_char(v_min_offer, 'FM999,999,999'),
      to_char(coalesce(v_current, 0), 'FM999,999,999'),
      to_char(v_step, 'FM999,999,999');
  END IF;

  v_season := coalesce(public.current_gpsl_season_label(), 'unknown');

  INSERT INTO public.contract_expiry_wage_bids (
    player_id,
    bidder_club_short_name,
    wage_offer,
    season_label,
    updated_at
  )
  VALUES (v_pid, v_club, v_wage, v_season, now())
  ON CONFLICT ON CONSTRAINT contract_expiry_wage_bids_unique
  DO UPDATE SET
    wage_offer = EXCLUDED.wage_offer,
    updated_at = now();

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'bidder_club_short_name', v_club,
    'wage_offer', v_wage,
    'min_wage_offer', v_min_offer,
    'wage_step', v_step,
    'season_label', v_season
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Market list: own bid only + min next offer hint
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_expiring_contract_market()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_viewer text;
  v_season text;
  v_out    jsonb := '[]'::jsonb;
  v_row    record;
  v_my_bid numeric;
  v_step   numeric := public.contract_expiry_wage_bid_step();
BEGIN
  v_season := coalesce(public.current_gpsl_season_label(), 'unknown');

  BEGIN
    v_viewer := public.my_club_shortname();
  EXCEPTION
    WHEN OTHERS THEN
      v_viewer := NULL;
  END;

  FOR v_row IN
    SELECT
      p."Konami_ID"::text AS player_id,
      p."Name" AS player_name,
      p."Position" AS position,
      p."Rating" AS rating,
      p."Age" AS age,
      p.market_value,
      p."Contracted_Team" AS holding_club,
      p.contract_wage AS current_wage
    FROM public."Players" p
    WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
      AND coalesce(p.contract_seasons_remaining, 0) = 1
      AND NOT public.is_player_homegrown_u23(
        p."Konami_ID"::text,
        public.player_contracted_club_key(p."Contracted_Team")
      )
    ORDER BY p."Name"
  LOOP
    v_my_bid := NULL;
    IF v_viewer IS NOT NULL THEN
      SELECT b.wage_offer
      INTO v_my_bid
      FROM public.contract_expiry_wage_bids b
      WHERE b.player_id = v_row.player_id
        AND b.season_label = v_season
        AND b.bidder_club_short_name = v_viewer;
    END IF;

    v_out := v_out || jsonb_build_array(
      jsonb_build_object(
        'player_id', v_row.player_id,
        'player_name', v_row.player_name,
        'position', v_row.position,
        'rating', v_row.rating,
        'age', v_row.age,
        'market_value', v_row.market_value,
        'holding_club', v_row.holding_club,
        'current_wage', v_row.current_wage,
        'min_wage_offer', public.contract_expiry_min_wage_offer(v_row.current_wage),
        'wage_step', v_step,
        'my_wage_bid', v_my_bid,
        'season_label', v_season
      )
    );
  END LOOP;

  RETURN coalesce(v_out, '[]'::jsonb);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Resolve expiry bids at rollover
-- ---------------------------------------------------------------------------
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
  v_signing_fee  numeric := public.contract_expiry_champ_sl_signing_fee();
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

    -- Another club wins: MV compensation to holding club (+ optional Champ→SL bank fee)
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
        PERFORM public.post_club_ledger(
          v_bid.bidder_club_short_name,
          'contract_expiry_champ_signing_fee',
          -v_signing_fee,
          'Championship signing-on fee (SL player expiry): '
            || coalesce(v_player_name, v_player.player_id),
          v_meta || jsonb_build_object(
            'signing_fee', v_signing_fee,
            'holder_tier', v_holder_tier,
            'winner_tier', v_winner_tier
          ),
          NULL,
          NULL,
          true,  -- bank leg → Central Bank
          true
        );
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

GRANT EXECUTE ON FUNCTION public.contract_expiry_wage_bid_step() TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_expiry_champ_sl_signing_fee() TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_expiry_min_wage_offer(numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_submit_expiry_wage_bid(text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_expiring_contract_market() TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_resolve_all_expiry_bids() TO authenticated;

NOTIFY pgrst, 'reload schema';
