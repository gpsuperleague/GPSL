-- =============================================================================
-- Contract expiry rollover 竊・post money on the NEW season
--
-- Problem:
--   Bids are stored under the ending season label. Resolve used
--   current_gpsl_season_label() + post_club_ledger(NULL season) 竊・wrong/
--   missing season after Close Finances + End Season. FA releases bumped
--   cash with no ledger season line.
--
-- Fix:
--   1) Create next pre-season FIRST (Season N+1)
--   2) Tick looks up bids from Season N label
--   3) All ledger / MV / FA lines post to Season N+1
--   4) Season_Signed set to the new season label
--
-- Run this WHOLE file in Supabase SQL Editor before Create Pre-Season / Tick.
-- Safe re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Context: ledger = newest preseason/setup; bids = previous season label
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.contract_rollover_finance_context()
RETURNS TABLE (
  ledger_season_id bigint,
  ledger_season_label text,
  bid_season_id bigint,
  bid_season_label text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ledger record;
  v_bid record;
BEGIN
  SELECT s.id, s.label, s.status
  INTO v_ledger
  FROM public.competition_seasons s
  WHERE s.status IN ('preseason', 'setup')
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_ledger.id IS NULL THEN
    RAISE EXCEPTION
      'Create the next pre-season first 窶・expiry transfers and FA releases must post to the new season (not the closed year).';
  END IF;

  SELECT s.id, s.label
  INTO v_bid
  FROM public.competition_seasons s
  WHERE s.id < v_ledger.id
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_bid.id IS NULL THEN
    RAISE EXCEPTION
      'No prior season found to read expiry wage bids from (ledger season id %).',
      v_ledger.id;
  END IF;

  ledger_season_id := v_ledger.id;
  ledger_season_label := btrim(v_ledger.label);
  bid_season_id := v_bid.id;
  bid_season_label := btrim(v_bid.label);
  RETURN NEXT;
END;
$function$;

COMMENT ON FUNCTION public.contract_rollover_finance_context() IS
  'Expiry rollover: ledger posts 竊・newest preseason/setup; wage bids 竊・previous season label.';

GRANT EXECUTE ON FUNCTION public.contract_rollover_finance_context() TO authenticated;

-- Drop legacy 0-arg resolve (replaced by defaulted args below)
DROP FUNCTION IF EXISTS public.contract_resolve_all_expiry_bids();

-- ---------------------------------------------------------------------------
-- Resolve expiry bids 竊・new season ledger
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
        AND b.season_label = v_bid_label;
      CONTINUE;
    END IF;

    SELECT b.bidder_club_short_name, b.wage_offer
    INTO v_bid
    FROM public.contract_expiry_wage_bids b
    WHERE b.player_id = v_player.player_id
      AND b.season_label = v_bid_label
    ORDER BY
      b.wage_offer DESC,
      CASE WHEN b.bidder_club_short_name = v_holder THEN 0 ELSE 1 END,
      b.created_at ASC
    LIMIT 1;

    -- Fallback: label drift / testing 窶・take best bid for this player
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
        player_id,
        seller_club_id,
        buyer_club_id,
        fee,
        agent_fee,
        transfer_time,
        listing_id,
        transfer_sale_note
      )
      VALUES (
        v_player.player_id,
        v_holder,
        v_bid.bidder_club_short_name,
        v_mv,
        0,
        now(),
        NULL,
        'contract_expiry'
      );
    END IF;

    -- Explicit 4-arg call — avoids overload ambiguity with (text,text,numeric)
    PERFORM public.player_assign_to_club(
      v_player.player_id,
      v_bid.bidder_club_short_name,
      v_bid.wage_offer,
      false
    );

    -- Assign uses current_gpsl_season_label() which is often NULL after End Season
    UPDATE public."Players" p
    SET "Season_Signed" = v_ledger_label
    WHERE p."Konami_ID"::text = v_player.player_id;

    DELETE FROM public.contract_expiry_wage_bids b
    WHERE b.player_id = v_player.player_id
      AND (
        b.season_label = v_bid_label
        OR b.season_label IS NOT DISTINCT FROM v_bid_label
      );

    -- Clear any leftover bids for this player (other labels)
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

GRANT EXECUTE ON FUNCTION public.contract_resolve_all_expiry_bids(bigint, text) TO authenticated;

-- Drop legacy 0-arg release
DROP FUNCTION IF EXISTS public.contract_release_zero_year_players();

-- ---------------------------------------------------------------------------
-- FA / unsigned release 竊・new season ledger + Transfer_History
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.contract_release_zero_year_players(
  p_ledger_season_id bigint DEFAULT NULL
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_count int := 0;
  v_ledger_id bigint := p_ledger_season_id;
  v_ledger_label text;
  v_ctx record;
BEGIN
  PERFORM public.ensure_foreign_buyer_club();

  IF v_ledger_id IS NULL THEN
    SELECT * INTO v_ctx FROM public.contract_rollover_finance_context();
    v_ledger_id := v_ctx.ledger_season_id;
    v_ledger_label := v_ctx.ledger_season_label;
  ELSE
    SELECT btrim(s.label) INTO v_ledger_label
    FROM public.competition_seasons s
    WHERE s.id = v_ledger_id;
  END IF;

  IF v_ledger_id IS NULL THEN
    RAISE EXCEPTION 'No ledger season for contract FA releases';
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS _contract_expire_batch (
    player_id text PRIMARY KEY,
    club text NOT NULL,
    fee numeric NOT NULL DEFAULT 0,
    player_name text
  ) ON COMMIT DROP;

  DELETE FROM _contract_expire_batch;

  INSERT INTO _contract_expire_batch (player_id, club, fee, player_name)
  SELECT
    p."Konami_ID"::text,
    public.player_contracted_club_key(p."Contracted_Team"),
    greatest(coalesce(p.market_value::numeric, 0), 0),
    p."Name"
  FROM public."Players" p
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining IS NOT NULL
    AND p.contract_seasons_remaining <= 0;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count = 0 THEN
    RETURN 0;
  END IF;

  -- Ledger lines on NEW season (cash via post path below)
  INSERT INTO public.competition_finance_ledger (
    season_id,
    fixture_id,
    club_short_name,
    entry_type,
    amount,
    description,
    metadata
  )
  SELECT
    v_ledger_id,
    NULL,
    e.club,
    'transfer_foreign_sale',
    e.fee,
    'Contract expired (free agent): ' || coalesce(e.player_name, e.player_id),
    jsonb_build_object(
      'player_id', e.player_id,
      'player_name', e.player_name,
      'holding_club', e.club,
      'buyer', 'FOREIGN',
      'market_value', e.fee,
      'ledger_season_id', v_ledger_id,
      'ledger_season_label', v_ledger_label,
      'source', 'contract_expiry_fa'
    )
  FROM _contract_expire_batch e
  WHERE e.fee > 0;

  UPDATE public."Club_Finances" cf
  SET balance = cf.balance + x.total_fee
  FROM (
    SELECT club, sum(fee)::numeric AS total_fee
    FROM _contract_expire_batch
    GROUP BY club
  ) x
  WHERE cf.club_name = x.club
    AND x.total_fee <> 0;

  UPDATE public."Players" p
  SET
    "Contracted_Team" = NULL,
    "Season_Signed" = NULL,
    contract_seasons_remaining = NULL,
    contract_wage = NULL
  FROM _contract_expire_batch e
  WHERE p."Konami_ID"::text = e.player_id;

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
  SELECT
    e.player_id,
    e.club,
    'FOREIGN',
    e.fee,
    0,
    now(),
    NULL,
    'Contract expired (free agent)',
    'contract_expiry'
  FROM _contract_expire_batch e;

  RETURN v_count;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.contract_release_zero_year_players(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Contract tick 窶・uses new-season ledger context
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.contract_tick_season_rollover()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_resolve jsonb;
  v_updated int;
  v_ended   int;
  v_final   int;
  v_released int;
  v_out jsonb;
  v_ctx record;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  PERFORM set_config('statement_timeout', '180s', true);

  SELECT * INTO v_ctx FROM public.contract_rollover_finance_context();

  v_resolve := public.contract_resolve_all_expiry_bids(
    v_ctx.ledger_season_id,
    v_ctx.bid_season_label
  );

  -- Anyone still at remaining=1 was not re-signed 竊・end (FA + MV)
  UPDATE public."Players" p
  SET contract_seasons_remaining = 0
  WHERE public.player_contracted_club_key(p."Contracted_Team") IS NOT NULL
    AND p.contract_seasons_remaining = 1;

  GET DIAGNOSTICS v_ended = ROW_COUNT;

  v_released := public.contract_release_zero_year_players(v_ctx.ledger_season_id);

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
    'bid_season_label', v_ctx.bid_season_label,
    'ledger_season_id', v_ctx.ledger_season_id,
    'ledger_season_label', v_ctx.ledger_season_label,
    'expiry_resolved', v_resolve,
    'players_contract_ended_unsigned', v_ended,
    'players_released_zero_years', v_released,
    'players_decremented', v_updated,
    'players_final_year', v_final,
    'note', 'Bids from ending season; money + FA on new preseason; then decrement into new final year.'
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

GRANT EXECUTE ON FUNCTION public.contract_tick_season_rollover() TO authenticated;

-- Keep catch-up wrapper (same entry point as Admin UI)
CREATE OR REPLACE FUNCTION public.admin_catchup_player_contract_tick(
  p_force boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_newest record;
  v_out jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT s.id, s.label, s.status INTO v_newest
  FROM public.competition_seasons s
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_newest.id IS NULL THEN
    RAISE EXCEPTION 'No competition seasons found';
  END IF;

  IF v_newest.status NOT IN ('preseason', 'setup') THEN
    RAISE EXCEPTION
      'Newest season "%" (%) is not preseason/setup. Create the next pre-season first so expiry money posts there.',
      v_newest.label, v_newest.status;
  END IF;

  IF NOT coalesce(p_force, false)
     AND EXISTS (
       SELECT 1 FROM public.competition_contract_tick_log l
       WHERE l.for_season_id = v_newest.id
     )
  THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'already_ticked',
      'for_season_id', v_newest.id,
      'for_season_label', v_newest.label,
      'hint', 'A player contract tick is already logged for this season. Pass p_force := true only if you are sure it never applied.'
    );
  END IF;

  PERFORM set_config('statement_timeout', '180s', true);

  v_out := public.contract_tick_season_rollover();

  -- tick already logs; ensure row if force re-run
  IF coalesce(p_force, false) THEN
    INSERT INTO public.competition_contract_tick_log (for_season_id, for_season_label, result)
    VALUES (v_newest.id, v_newest.label, coalesce(v_out, '{}'::jsonb));
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'for_season_id', v_newest.id,
    'for_season_label', v_newest.label,
    'tick', v_out
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_catchup_player_contract_tick(boolean)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
