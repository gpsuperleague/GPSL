-- =============================================================================
-- GPSL — Transfer polish: below-reserve seller RPCs + ledger for all deal types
-- Run once after central_bank_phase1.sql (and competition_fines.sql if applied).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Ledger types for special auctions
-- ---------------------------------------------------------------------------

ALTER TABLE public.competition_finance_ledger
  DROP CONSTRAINT IF EXISTS competition_finance_ledger_entry_type_check;

ALTER TABLE public.competition_finance_ledger
  ADD CONSTRAINT competition_finance_ledger_entry_type_check
  CHECK (
    entry_type IN (
      'gate_league_home',
      'gate_cup_share',
      'prize',
      'prize_league',
      'prize_cup',
      'prize_challenge',
      'tv_revenue',
      'gov_hg_subsidy',
      'gov_youth_subsidy',
      'gov_bnb_subsidy',
      'gov_fine_compensation',
      'gov_emergency_tax',
      'gov_income_tax',
      'wage_squad',
      'wage_renewal_34plus',
      'wage_star_tax',
      'adjustment',
      'admin_one_off_injection',
      'admin_purchase_payment',
      'transfer_sale',
      'transfer_purchase',
      'transfer_agent_fee',
      'transfer_foreign_sale',
      'transfer_overflow_release',
      'special_auction_fee',
      'special_auction_prize',
      'loan_drawdown',
      'loan_repayment_principal',
      'loan_interest_payment',
      'infra_maintenance',
      'infra_purchase',
      'infra_expansion',
      'infra_expansion_refund',
      'infra_expansion_penalty'
    )
  );

-- ---------------------------------------------------------------------------
-- Transfer history → ledger (foreign sales + idempotency fix)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.post_transfer_ledger_for_history(
  p_transfer_history_id bigint,
  p_apply_balance boolean DEFAULT true
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_h record;
  v_player_name text;
  v_desc_buy text;
  v_desc_sell text;
  v_meta jsonb;
  v_sell_type text;
BEGIN
  SELECT *
  INTO v_h
  FROM public."Transfer_History" h
  WHERE h.id = p_transfer_history_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_meta := jsonb_build_object(
    'transfer_history_id', v_h.id,
    'listing_id', v_h.listing_id,
    'player_id', v_h.player_id
  );

  IF EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.metadata->>'transfer_history_id' = v_h.id::text
      AND l.entry_type IN (
        'transfer_sale',
        'transfer_purchase',
        'transfer_foreign_sale',
        'transfer_overflow_release',
        'transfer_agent_fee'
      )
    LIMIT 1
  ) THEN
    RETURN;
  END IF;

  SELECT p."Name" INTO v_player_name
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_h.player_id::text
  LIMIT 1;

  v_player_name := coalesce(v_player_name, 'Player ' || v_h.player_id::text);

  IF v_h.buyer_club_id IS NOT NULL
     AND btrim(v_h.buyer_club_id::text) <> ''
     AND v_h.buyer_club_id <> 'FOREIGN' THEN
    v_desc_buy := 'Purchase: ' || v_player_name;
    PERFORM public.post_club_ledger(
      v_h.buyer_club_id,
      'transfer_purchase',
      -abs(v_h.fee),
      v_desc_buy,
      v_meta,
      NULL,
      NULL,
      false,
      p_apply_balance
    );
  END IF;

  IF v_h.seller_club_id IS NOT NULL AND btrim(v_h.seller_club_id::text) <> '' THEN
    v_desc_sell := 'Sale: ' || v_player_name;
    IF coalesce(v_h.transfer_sale_note, '') = 'squad_overflow' THEN
      v_sell_type := CASE
        WHEN v_h.buyer_club_id = 'FOREIGN' THEN 'transfer_foreign_sale'
        ELSE 'transfer_overflow_release'
      END;
      PERFORM public.post_club_ledger(
        v_h.seller_club_id,
        v_sell_type,
        abs(v_h.fee),
        coalesce(nullif(btrim(v_h.foreign_buyer_name), ''), v_desc_sell),
        v_meta || jsonb_build_object('transfer_sale_note', v_h.transfer_sale_note),
        NULL,
        NULL,
        false,
        p_apply_balance
      );
    ELSIF v_h.buyer_club_id = 'FOREIGN' THEN
      PERFORM public.post_club_ledger(
        v_h.seller_club_id,
        'transfer_foreign_sale',
        abs(v_h.fee),
        coalesce(nullif(btrim(v_h.foreign_buyer_name), ''), v_desc_sell),
        v_meta,
        NULL,
        NULL,
        false,
        p_apply_balance
      );
    ELSE
      PERFORM public.post_club_ledger(
        v_h.seller_club_id,
        'transfer_sale',
        abs(v_h.fee),
        v_desc_sell,
        v_meta,
        NULL,
        NULL,
        false,
        p_apply_balance
      );
    END IF;
  END IF;

  IF coalesce(v_h.agent_fee, 0) > 0
     AND v_h.buyer_club_id IS NOT NULL
     AND v_h.buyer_club_id <> 'FOREIGN' THEN
    PERFORM public.post_club_ledger(
      v_h.buyer_club_id,
      'transfer_agent_fee',
      -abs(v_h.agent_fee),
      'Agent fee: ' || v_player_name,
      v_meta,
      NULL,
      NULL,
      false,
      p_apply_balance
    );
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Special auction ledger lines (balance already updated by settle)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.post_special_auction_ledger_line(
  p_club_short_name text,
  p_entry_type text,
  p_amount numeric,
  p_description text,
  p_auction_id bigint,
  p_apply_balance boolean DEFAULT false,
  p_extra_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_meta jsonb;
BEGIN
  IF v_club IS NULL OR v_club = '' OR p_amount IS NULL OR p_amount = 0 THEN
    RETURN NULL;
  END IF;

  v_meta := jsonb_build_object('special_auction_id', p_auction_id)
    || coalesce(p_extra_metadata, '{}'::jsonb);

  IF EXISTS (
    SELECT 1
    FROM public.competition_finance_ledger l
    WHERE l.club_short_name = v_club
      AND l.entry_type = p_entry_type
      AND l.metadata->>'special_auction_id' = p_auction_id::text
      AND coalesce(l.metadata->>'ledger_role', '') =
          coalesce(v_meta->>'ledger_role', '')
    LIMIT 1
  ) THEN
    RETURN NULL;
  END IF;

  RETURN public.post_club_ledger(
    v_club,
    p_entry_type,
    p_amount,
    p_description,
    v_meta,
    NULL,
    NULL,
    false,
    p_apply_balance
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Below-reserve seller actions (Transfer Centre UI)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_accept_below_reserve_sale(p_listing_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club   text;
  v_listing public."Player_Transfer_Listings"%rowtype;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Listing not found';
  END IF;

  IF v_listing.seller_club_id IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'This listing is not yours';
  END IF;

  IF v_listing.status NOT IN ('Review', 'Seller Review') THEN
    RAISE EXCEPTION 'Listing is not awaiting seller review (status: %)', v_listing.status;
  END IF;

  IF v_listing.current_highest_bid IS NULL OR v_listing.current_highest_bidder IS NULL THEN
    RAISE EXCEPTION 'No highest bid on this listing';
  END IF;

  IF v_listing.seller_review_deadline IS NOT NULL
     AND v_listing.seller_review_deadline < now() THEN
    RAISE EXCEPTION 'Seller review window has expired';
  END IF;

  PERFORM public.transferengine_sync_listing_high_bid(p_listing_id);

  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id;

  PERFORM public.transferengine_accept_sale(p_listing_id);

  RETURN jsonb_build_object(
    'ok', true,
    'listing_id', p_listing_id,
    'buyer', v_listing.current_highest_bidder,
    'fee', v_listing.current_highest_bid
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_reject_below_reserve_sale(p_listing_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club   text;
  v_listing public."Player_Transfer_Listings"%rowtype;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Listing not found';
  END IF;

  IF v_listing.seller_club_id IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'This listing is not yours';
  END IF;

  IF v_listing.status NOT IN ('Review', 'Seller Review') THEN
    RAISE EXCEPTION 'Listing is not awaiting seller review (status: %)', v_listing.status;
  END IF;

  PERFORM public.transferengine_reject_sale(p_listing_id);

  UPDATE public."Player_Transfer_Bids" b
  SET status = 'rejected'
  WHERE b.listing_id = p_listing_id
    AND lower(coalesce(b.status::text, '')) = 'active';

  RETURN jsonb_build_object('ok', true, 'listing_id', p_listing_id);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Patch deal paths: ledger only (balance already applied in-function)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.sell_player_to_foreign_club(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club           text;
  v_player         public."Players"%rowtype;
  v_pid            text;
  v_fee            numeric;
  v_seller_balance numeric;
  v_buyer          text := 'FOREIGN';
  v_interest       int;
  v_interest_after int;
  v_history_id     bigint;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  PERFORM public.ensure_foreign_buyer_club();

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT c.foreign_interest_remaining
  INTO v_interest
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club
  FOR UPDATE;

  IF coalesce(v_interest, 0) <= 0 THEN
    RAISE EXCEPTION
      'No foreign clubs are interested in your players (maximum foreign sales reached).';
  END IF;

  v_pid := btrim(p_player_id);

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at your club';
  END IF;

  PERFORM public.assert_player_transferable(v_pid);

  v_fee := greatest(coalesce(v_player.market_value::numeric, 0::numeric), 0::numeric);

  SELECT balance
  INTO v_seller_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_seller_balance IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false,
      winning_bid = null,
      winning_club = null
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Review');

  UPDATE public."Player_Transfer_Bids" b
  SET status = 'rejected'
  WHERE b.is_direct = true
    AND b.listing_id IS NULL
    AND lower(coalesce(b.status::text, '')) = 'active'
    AND (
      (b.player_id IS NOT NULL AND btrim(b.player_id::text) = v_pid)
      OR (b.direct_bid_id IS NOT NULL AND btrim(b.direct_bid_id::text) = v_pid)
    );

  PERFORM public.player_release_from_club(v_pid);

  UPDATE public."Club_Finances"
  SET balance = v_seller_balance + v_fee
  WHERE club_name = v_club;

  UPDATE public."Clubs" c
  SET foreign_interest_remaining = foreign_interest_remaining - 1
  WHERE c."ShortName" = v_club
  RETURNING c.foreign_interest_remaining INTO v_interest_after;

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
    v_player."Konami_ID",
    v_club,
    v_buyer,
    v_fee,
    0,
    now(),
    NULL
  )
  RETURNING id INTO v_history_id;

  PERFORM public.post_transfer_ledger_for_history(v_history_id, false);

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_player."Konami_ID",
    'player_name', v_player."Name",
    'seller_club_id', v_club,
    'buyer_club_id', v_buyer,
    'fee', v_fee,
    'new_balance', v_seller_balance + v_fee,
    'foreign_interest_remaining', v_interest_after
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_contract_expire(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club           text;
  v_player         public."Players"%rowtype;
  v_pid            text := btrim(p_player_id);
  v_fee            numeric;
  v_seller_balance numeric;
  v_history_id     bigint;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at your club';
  END IF;

  IF coalesce(v_player.contract_seasons_remaining, 0) <> 1 THEN
    RAISE EXCEPTION 'Contract expiry is only available in the final contract year (1 season remaining)';
  END IF;

  v_fee := greatest(coalesce(v_player.market_value::numeric, 0::numeric), 0::numeric);

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Review');

  SELECT balance
  INTO v_seller_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_seller_balance IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  PERFORM public.player_release_from_club(v_pid);

  UPDATE public."Club_Finances"
  SET balance = v_seller_balance + v_fee
  WHERE club_name = v_club;

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
    v_player."Konami_ID",
    v_club,
    NULL,
    v_fee,
    0,
    now(),
    NULL,
    'contract_expiry'
  )
  RETURNING id INTO v_history_id;

  PERFORM public.post_transfer_ledger_for_history(v_history_id, false);

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_player."Konami_ID",
    'player_name', v_player."Name",
    'fee', v_fee,
    'new_balance', v_seller_balance + v_fee
  );
END;
$function$;

-- Squad overflow releases (MV + foreign slot)
CREATE OR REPLACE FUNCTION public.club_release_player_mv_overflow(
  p_club_short_name text,
  p_player_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club       text := btrim(p_club_short_name);
  v_pid        text := btrim(p_player_id);
  v_player     public."Players"%rowtype;
  v_fee        numeric;
  v_bal        numeric;
  v_history_id bigint;
BEGIN
  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at club %', v_club;
  END IF;

  v_fee := greatest(coalesce(v_player.market_value::numeric, 0), 0);

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false,
      winning_bid = null,
      winning_club = null
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Review');

  UPDATE public."Player_Transfer_Bids" b
  SET status = 'rejected'
  WHERE b.is_direct = true
    AND b.listing_id IS NULL
    AND lower(coalesce(b.status::text, '')) = 'active'
    AND (
      (b.player_id IS NOT NULL AND btrim(b.player_id::text) = v_pid)
      OR (b.direct_bid_id IS NOT NULL AND btrim(b.direct_bid_id::text) = v_pid)
    );

  SELECT balance INTO v_bal
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_bal IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  PERFORM public.ensure_foreign_buyer_club();
  PERFORM public.player_release_from_club(v_pid);

  UPDATE public."Club_Finances"
  SET balance = v_bal + v_fee
  WHERE club_name = v_club;

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
    v_player."Konami_ID",
    v_club,
    'FOREIGN',
    v_fee,
    0,
    now(),
    NULL,
    'Market value (squad over 28)',
    'squad_overflow'
  )
  RETURNING id INTO v_history_id;

  PERFORM public.post_transfer_ledger_for_history(v_history_id, false);

  RETURN jsonb_build_object(
    'ok', true,
    'method', 'market_value',
    'player_id', v_pid,
    'player_name', v_player."Name",
    'rating', v_player."Rating",
    'fee', v_fee
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_release_player_foreign_overflow(
  p_club_short_name text,
  p_player_id text,
  p_foreign_team_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club           text := btrim(p_club_short_name);
  v_pid            text := btrim(p_player_id);
  v_team           text := btrim(p_foreign_team_name);
  v_player         public."Players"%rowtype;
  v_fee            numeric;
  v_bal            numeric;
  v_interest       int;
  v_interest_after int;
  v_teams          text[];
  v_history_id     bigint;
BEGIN
  PERFORM public.ensure_foreign_buyer_club();

  IF v_team = '' THEN
    RAISE EXCEPTION 'Foreign buyer name required for overflow foreign sale';
  END IF;

  SELECT c.foreign_interest_remaining, coalesce(c.foreign_tracking_teams, '{}')
  INTO v_interest, v_teams
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club
  FOR UPDATE;

  IF coalesce(v_interest, 0) <= 0 THEN
    RAISE EXCEPTION 'No foreign club interest remaining for %', v_club;
  END IF;

  v_teams := public.sync_club_foreign_tracking(v_club);

  IF NOT (v_team = ANY (v_teams)) THEN
    RAISE EXCEPTION 'Club % is not tracking your players', v_team;
  END IF;

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at club %', v_club;
  END IF;

  v_fee := greatest(coalesce(v_player.market_value::numeric, 0), 0);

  SELECT balance INTO v_bal
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_bal IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false,
      winning_bid = null,
      winning_club = null
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Review');

  UPDATE public."Player_Transfer_Bids" b
  SET status = 'rejected'
  WHERE b.is_direct = true
    AND b.listing_id IS NULL
    AND lower(coalesce(b.status::text, '')) = 'active'
    AND (
      (b.player_id IS NOT NULL AND btrim(b.player_id::text) = v_pid)
      OR (b.direct_bid_id IS NOT NULL AND btrim(b.direct_bid_id::text) = v_pid)
    );

  PERFORM public.player_release_from_club(v_pid);

  UPDATE public."Club_Finances"
  SET balance = v_bal + v_fee
  WHERE club_name = v_club;

  v_teams := array_remove(v_teams, v_team);

  UPDATE public."Clubs" c
  SET foreign_interest_remaining = foreign_interest_remaining - 1,
      foreign_tracking_teams = v_teams
  WHERE c."ShortName" = v_club
  RETURNING c.foreign_interest_remaining INTO v_interest_after;

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
    v_player."Konami_ID",
    v_club,
    'FOREIGN',
    v_fee,
    0,
    now(),
    NULL,
    v_team,
    'squad_overflow'
  )
  RETURNING id INTO v_history_id;

  PERFORM public.post_transfer_ledger_for_history(v_history_id, false);

  RETURN jsonb_build_object(
    'ok', true,
    'method', 'foreign_overflow',
    'player_id', v_pid,
    'player_name', v_player."Name",
    'foreign_team', v_team,
    'fee', v_fee,
    'foreign_interest_remaining', v_interest_after
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Special auctions → ledger
-- ---------------------------------------------------------------------------

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
  v_player "Players"%rowtype;
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
      PERFORM public.player_assign_to_club(
        p_auction.prize_player_id,
        p_winner_club
      );
    END IF;
  ELSIF p_auction.prize_type = 'cash' AND coalesce(p_auction.prize_cash_amount, 0) > 0 THEN
    UPDATE public."Club_Finances"
    SET balance = balance + p_auction.prize_cash_amount
    WHERE club_name = p_winner_club;

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
END;
$function$;

CREATE OR REPLACE FUNCTION public.special_auction_settle(p_auction_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_auction public.special_auctions%rowtype;
  v_win_club text;
  v_win_amount numeric;
  v_bid record;
  v_fee numeric;
  v_balance numeric;
  v_title text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_auction FROM public.special_auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Auction not found'; END IF;

  v_title := coalesce(v_auction.title, 'Auction #' || v_auction.id);

  IF v_auction.auction_type = 'lowest_unique' THEN
    IF v_auction.status = 'active' THEN
      PERFORM public.special_auction_reveal_lowest_unique(p_auction_id);
      SELECT * INTO v_auction FROM public.special_auctions WHERE id = p_auction_id;
    END IF;
    IF v_auction.status NOT IN ('revealed', 'settled') THEN
      RAISE EXCEPTION 'Reveal the lowest unique auction first';
    END IF;
    v_win_club := v_auction.winning_club_id;
    v_win_amount := v_auction.winning_amount;

    IF v_win_club IS NULL THEN
      UPDATE public.special_auctions SET status = 'settled', updated_at = now() WHERE id = p_auction_id;
      RETURN;
    END IF;

    SELECT balance INTO v_balance FROM public."Club_Finances" WHERE club_name = v_win_club FOR UPDATE;
    UPDATE public."Club_Finances"
    SET balance = coalesce(v_balance, 0) - v_win_amount
    WHERE club_name = v_win_club;

    PERFORM public.post_special_auction_ledger_line(
      v_win_club,
      'special_auction_fee',
      -abs(v_win_amount),
      format('Lowest unique bid — %s', v_title),
      p_auction_id,
      false,
      jsonb_build_object('ledger_role', 'lub_win', 'auction_type', 'lowest_unique')
    );

    UPDATE public.special_auction_bids
    SET fee_charged = v_win_amount
    WHERE auction_id = p_auction_id AND club_id = v_win_club;

    PERFORM public.special_auction_award_prize(v_auction, v_win_club, v_win_amount);

  ELSIF v_auction.auction_type = 'snap' THEN
    SELECT club_id, bid_amount
    INTO v_win_club, v_win_amount
    FROM public.special_auction_bids
    WHERE auction_id = p_auction_id
    ORDER BY bid_amount DESC, bid_time ASC
    LIMIT 1;

    UPDATE public.special_auction_bids SET is_winner = false WHERE auction_id = p_auction_id;
    IF v_win_club IS NOT NULL THEN
      UPDATE public.special_auction_bids SET is_winner = true
      WHERE auction_id = p_auction_id AND club_id = v_win_club;
    END IF;

    FOR v_bid IN
      SELECT club_id, bid_amount FROM public.special_auction_bids WHERE auction_id = p_auction_id
    LOOP
      IF v_bid.club_id = v_win_club THEN
        v_fee := coalesce(v_auction.snap_win_fee, 500000) + coalesce(v_win_amount, 0);
      ELSE
        v_fee := coalesce(v_auction.snap_loss_fee, 250000);
      END IF;

      SELECT balance INTO v_balance FROM public."Club_Finances" WHERE club_name = v_bid.club_id FOR UPDATE;
      IF v_balance IS NOT NULL THEN
        UPDATE public."Club_Finances" SET balance = v_balance - v_fee WHERE club_name = v_bid.club_id;
      END IF;

      PERFORM public.post_special_auction_ledger_line(
        v_bid.club_id,
        'special_auction_fee',
        -abs(v_fee),
        format(
          'Snap auction %s — %s',
          CASE WHEN v_bid.club_id = v_win_club THEN 'win' ELSE 'loss' END,
          v_title
        ),
        p_auction_id,
        false,
        jsonb_build_object(
          'ledger_role',
          CASE WHEN v_bid.club_id = v_win_club THEN 'snap_win' ELSE 'snap_loss' END,
          'auction_type', 'snap',
          'bid_amount', v_bid.bid_amount
        )
      );

      UPDATE public.special_auction_bids SET fee_charged = v_fee
      WHERE auction_id = p_auction_id AND club_id = v_bid.club_id;
    END LOOP;

    UPDATE public.special_auctions
    SET winning_club_id = v_win_club,
        winning_amount = v_win_amount,
        status = 'settled',
        updated_at = now()
    WHERE id = p_auction_id;

    PERFORM public.special_auction_award_prize(v_auction, v_win_club, v_win_amount);
  END IF;

  IF v_auction.auction_type = 'lowest_unique' AND v_auction.status = 'revealed' THEN
    UPDATE public.special_auctions SET status = 'settled', updated_at = now() WHERE id = p_auction_id;
  END IF;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_accept_below_reserve_sale(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_reject_below_reserve_sale(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.post_special_auction_ledger_line(text, text, numeric, text, bigint, boolean, jsonb) TO authenticated;

-- Backfill: SQL Editor has no JWT — allow service-role / dashboard runs (auth.uid() IS NULL)
CREATE OR REPLACE FUNCTION public.backfill_transfer_finance_ledger()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_start timestamptz;
  v_h record;
  v_count int := 0;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT started_at INTO v_season_start
  FROM public.competition_seasons
  WHERE is_current = true AND status = 'active'
  LIMIT 1;

  FOR v_h IN
    SELECT h.id
    FROM public."Transfer_History" h
    WHERE v_season_start IS NULL OR h.transfer_time >= v_season_start
    ORDER BY h.transfer_time
  LOOP
    PERFORM public.post_transfer_ledger_for_history(v_h.id, false);
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.backfill_transfer_finance_ledger() TO authenticated;

NOTIFY pgrst, 'reload schema';
