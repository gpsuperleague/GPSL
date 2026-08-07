-- =============================================================================
-- Staged player contract tick (avoids API gateway timeout)
--
-- Symptom: admin_catchup_player_contract_tick / contract_tick_season_rollover
--   canceling statement due to statement timeout (even at 300s DB timeout —
--   PostgREST gateway often kills sooner).
--
-- Fix: three short RPCs (own timeout budget each):
--   1) contract_tick_rollover_step_fa()         — unrenewed FA + MV
--   2) contract_tick_rollover_step_contested() — expiry bid winners
--   3) contract_tick_rollover_step_decrement() — multi-year tick + log
--
-- Also: contested resolve only loops players who still have open bids
--   (was scanning every final-year auction candidate).
--
-- Season 21 already created — run in SQL Editor NOW:
--   SELECT public.contract_tick_rollover_step_fa();
--   SELECT public.contract_tick_rollover_step_contested();
--   SELECT public.contract_tick_rollover_step_decrement();
-- Or hard-refresh Admin → Tick contracts only (runs the three steps).
-- Safe to re-run each step.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Contested resolve: only players with open bids (faster)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.contract_resolve_all_expiry_bids(
  p_ledger_season_id bigint DEFAULT NULL,
  p_bid_season_label text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ctx          record;
  v_ledger_id    bigint;
  v_ledger_label text;
  v_bid_label    text;
  v_player       record;
  v_bid          record;
  v_resolved     int := 0;
  v_holder       text;
  v_mv           numeric;
  v_player_name  text;
  v_holder_tier  text;
  v_winner_tier  text;
  v_signing_fee  numeric;
  v_fee_pct      numeric := 15;
  v_meta         jsonb;
BEGIN
  PERFORM set_config('statement_timeout', '300s', true);

  IF p_ledger_season_id IS NOT NULL AND nullif(btrim(coalesce(p_bid_season_label, '')), '') IS NOT NULL THEN
    v_ledger_id := p_ledger_season_id;
    SELECT btrim(s.label) INTO v_ledger_label
    FROM public.competition_seasons s
    WHERE s.id = v_ledger_id;
    v_bid_label := btrim(p_bid_season_label);
  ELSE
    SELECT * INTO v_ctx FROM public.contract_rollover_finance_context();
    v_ledger_id := v_ctx.ledger_season_id;
    v_ledger_label := v_ctx.ledger_season_label;
    v_bid_label := v_ctx.bid_season_label;
  END IF;

  IF v_ledger_id IS NULL OR v_ledger_label IS NULL OR v_bid_label IS NULL THEN
    RAISE EXCEPTION 'Could not resolve rollover finance seasons';
  END IF;

  BEGIN
    v_fee_pct := public.contract_expiry_champ_sl_signing_fee_pct();
  EXCEPTION
    WHEN OTHERS THEN
      v_fee_pct := 15;
  END;

  -- Only players who still have open bids (not every final-year candidate)
  FOR v_player IN
    SELECT DISTINCT b.player_id
    FROM public.contract_expiry_wage_bids b
    WHERE b.season_label = v_bid_label
       OR b.season_label IS NOT DISTINCT FROM v_bid_label
  LOOP
    IF to_regprocedure('public.player_expiry_auction_applies(text)') IS NOT NULL
       AND NOT public.player_expiry_auction_applies(v_player.player_id)
    THEN
      DELETE FROM public.contract_expiry_wage_bids b
      WHERE b.player_id = v_player.player_id;
      CONTINUE;
    END IF;

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
        AND (
          b.season_label = v_bid_label
          OR b.season_label IS NOT DISTINCT FROM v_bid_label
        );
      CONTINUE;
    END IF;

    SELECT b.bidder_club_short_name, b.wage_offer
    INTO v_bid
    FROM public.contract_expiry_wage_bids b
    WHERE b.player_id = v_player.player_id
      AND (
        b.season_label = v_bid_label
        OR b.season_label IS NOT DISTINCT FROM v_bid_label
      )
    ORDER BY
      b.wage_offer DESC,
      CASE WHEN b.bidder_club_short_name = v_holder THEN 0 ELSE 1 END,
      b.created_at ASC
    LIMIT 1;

    IF NOT FOUND THEN
      SELECT b.bidder_club_short_name, b.wage_offer
      INTO v_bid
      FROM public.contract_expiry_wage_bids b
      WHERE b.player_id = v_player.player_id
      ORDER BY
        b.wage_offer DESC,
        CASE WHEN b.bidder_club_short_name = v_holder THEN 0 ELSE 1 END,
        b.created_at ASC
      LIMIT 1;
    END IF;

    IF NOT FOUND THEN
      CONTINUE;
    END IF;

    v_meta := jsonb_build_object(
      'player_id', v_player.player_id,
      'player_name', v_player_name,
      'holding_club', v_holder,
      'winner_club', v_bid.bidder_club_short_name,
      'wage_offer', v_bid.wage_offer,
      'bid_season_label', v_bid_label,
      'ledger_season_id', v_ledger_id,
      'ledger_season_label', v_ledger_label,
      'source', 'contract_expiry'
    );

    IF v_bid.bidder_club_short_name IS DISTINCT FROM v_holder THEN
      IF v_mv > 0 THEN
        PERFORM public.post_club_ledger(
          v_bid.bidder_club_short_name,
          'transfer_purchase',
          -v_mv,
          'Expiry market MV compensation: ' || coalesce(v_player_name, v_player.player_id),
          v_meta || jsonb_build_object('market_value', v_mv),
          v_ledger_id,
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
          v_ledger_id,
          NULL,
          false,
          true
        );
      END IF;

      BEGIN
        v_holder_tier := public.competition_club_division_tier(v_holder);
        v_winner_tier := public.competition_club_division_tier(v_bid.bidder_club_short_name);
      EXCEPTION
        WHEN OTHERS THEN
          v_holder_tier := NULL;
          v_winner_tier := NULL;
      END;

      IF v_holder_tier = 'superleague' AND v_winner_tier = 'championship' THEN
        v_signing_fee := round(v_mv * v_fee_pct / 100.0);
        IF v_signing_fee > 0 THEN
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
            v_ledger_id,
            NULL,
            false,
            true
          );
        END IF;
      END IF;

      INSERT INTO public."Transfer_History" (
        player_id, seller_club_id, buyer_club_id, fee, agent_fee,
        transfer_time, listing_id, transfer_sale_note
      )
      VALUES (
        v_player.player_id, v_holder, v_bid.bidder_club_short_name, v_mv, 0,
        now(), NULL, 'contract_expiry'
      );
    END IF;

    PERFORM public.player_assign_to_club(
      v_player.player_id,
      v_bid.bidder_club_short_name,
      v_bid.wage_offer,
      false
    );

    UPDATE public."Players" p
    SET "Season_Signed" = v_ledger_label
    WHERE p."Konami_ID"::text = v_player.player_id;

    DELETE FROM public.contract_expiry_wage_bids b
    WHERE b.player_id = v_player.player_id;

    v_resolved := v_resolved + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'bid_season_label', v_bid_label,
    'ledger_season_id', v_ledger_id,
    'ledger_season_label', v_ledger_label,
    'players_resolved', v_resolved
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Step 1: FA unrenewed (no open bids)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.contract_tick_rollover_step_fa()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ctx record;
  v_ended int;
  v_released int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '300s', true);

  SELECT * INTO v_ctx FROM public.contract_rollover_finance_context();

  UPDATE public."Players" p
  SET contract_seasons_remaining = 0
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining = 1
    AND NOT EXISTS (
      SELECT 1
      FROM public.contract_expiry_wage_bids b
      WHERE b.player_id = p."Konami_ID"::text
        AND (
          b.season_label = v_ctx.bid_season_label
          OR b.season_label IS NOT DISTINCT FROM v_ctx.bid_season_label
        )
    );

  GET DIAGNOSTICS v_ended = ROW_COUNT;

  v_released := public.contract_release_zero_year_players(v_ctx.ledger_season_id);

  RETURN jsonb_build_object(
    'ok', true,
    'step', 'fa',
    'ledger_season_id', v_ctx.ledger_season_id,
    'ledger_season_label', v_ctx.ledger_season_label,
    'bid_season_label', v_ctx.bid_season_label,
    'players_contract_ended_unsigned', v_ended,
    'players_released_zero_years', v_released
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Step 2: contested bid winners + leftover FA
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.contract_tick_rollover_step_contested()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ctx record;
  v_resolve jsonb;
  v_released int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '300s', true);

  SELECT * INTO v_ctx FROM public.contract_rollover_finance_context();

  v_resolve := public.contract_resolve_all_expiry_bids(
    v_ctx.ledger_season_id,
    v_ctx.bid_season_label
  );

  UPDATE public."Players" p
  SET contract_seasons_remaining = 0
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining = 1;

  v_released := public.contract_release_zero_year_players(v_ctx.ledger_season_id);

  RETURN jsonb_build_object(
    'ok', true,
    'step', 'contested',
    'ledger_season_id', v_ctx.ledger_season_id,
    'ledger_season_label', v_ctx.ledger_season_label,
    'expiry_resolved', v_resolve,
    'players_released_leftover', v_released
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Step 3: multi-year decrement + tick log
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.contract_tick_rollover_step_decrement()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ctx record;
  v_updated int;
  v_final int;
  v_out jsonb;
  v_open_bids int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '180s', true);

  SELECT * INTO v_ctx FROM public.contract_rollover_finance_context();

  SELECT count(*)::int INTO v_open_bids
  FROM public.contract_expiry_wage_bids b
  WHERE b.season_label = v_ctx.bid_season_label
     OR b.season_label IS NOT DISTINCT FROM v_ctx.bid_season_label;

  IF v_open_bids > 0 THEN
    RAISE EXCEPTION
      'Still % open expiry wage bid(s) for %. Run contract_tick_rollover_step_contested() first.',
      v_open_bids, v_ctx.bid_season_label;
  END IF;

  UPDATE public."Players" p
  SET contract_seasons_remaining = contract_seasons_remaining - 1
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining IS NOT NULL
    AND p.contract_seasons_remaining >= 2;

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  SELECT count(*)::int
  INTO v_final
  FROM public."Players" p
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining = 1;

  v_out := jsonb_build_object(
    'ok', true,
    'step', 'decrement',
    'bid_season_label', v_ctx.bid_season_label,
    'ledger_season_id', v_ctx.ledger_season_id,
    'ledger_season_label', v_ctx.ledger_season_label,
    'players_decremented', v_updated,
    'players_final_year', v_final,
    'note', 'Staged tick complete: FA → contested → decrement.'
  );

  IF NOT EXISTS (
    SELECT 1 FROM public.competition_contract_tick_log l
    WHERE l.for_season_id = v_ctx.ledger_season_id
  ) THEN
    INSERT INTO public.competition_contract_tick_log (for_season_id, for_season_label, result)
    VALUES (v_ctx.ledger_season_id, v_ctx.ledger_season_label, v_out);
  END IF;

  RETURN v_out;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.contract_resolve_all_expiry_bids(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_tick_rollover_step_fa() TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_tick_rollover_step_contested() TO authenticated;
GRANT EXECUTE ON FUNCTION public.contract_tick_rollover_step_decrement() TO authenticated;

NOTIFY pgrst, 'reload schema';
