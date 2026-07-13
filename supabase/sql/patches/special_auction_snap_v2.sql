-- =============================================================================
-- Special auction Snap v2 — clues, discounts, multi-bid fees, random end
-- Also: winner prize options (125% release / instant transfer list)
-- Run after special_auctions.sql. Safe to re-run.
-- =============================================================================

ALTER TABLE public.special_auctions
  ADD COLUMN IF NOT EXISTS clue_1 text,
  ADD COLUMN IF NOT EXISTS clue_2 text,
  ADD COLUMN IF NOT EXISTS clue_3 text,
  ADD COLUMN IF NOT EXISTS clue_4 text,
  ADD COLUMN IF NOT EXISTS snap_bid_fee numeric NOT NULL DEFAULT 300000,
  ADD COLUMN IF NOT EXISTS snap_random_end_at timestamptz,
  ADD COLUMN IF NOT EXISTS winner_discount_pct numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS winner_purchase_amount numeric,
  ADD COLUMN IF NOT EXISTS winner_prize_pending boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS winner_prize_resolved boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.special_auctions.snap_bid_fee IS
  'Per-bid fee for snap auctions (default ₿300,000). Winner pays 100%; losers 25%.';
COMMENT ON COLUMN public.special_auctions.snap_random_end_at IS
  'Actual snap close time, randomised into the final 10 minutes (after minute 50).';

-- Allow multiple snap bids per club (LUB still enforced in submit RPC)
ALTER TABLE public.special_auction_bids
  DROP CONSTRAINT IF EXISTS special_auction_bids_auction_id_club_id_key;

CREATE INDEX IF NOT EXISTS special_auction_bids_auction_club_idx
  ON public.special_auction_bids (auction_id, club_id, bid_time);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.special_auction_snap_effective_end(p_auction public.special_auctions)
RETURNS timestamptz
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_auction.auction_type = 'snap' AND p_auction.snap_random_end_at IS NOT NULL
      THEN p_auction.snap_random_end_at
    ELSE p_auction.end_time
  END;
$$;

CREATE OR REPLACE FUNCTION public.special_auction_snap_discount_pct(
  p_start timestamptz,
  p_first_bid timestamptz
)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_mins numeric;
BEGIN
  IF p_start IS NULL OR p_first_bid IS NULL THEN
    RETURN 0;
  END IF;
  v_mins := extract(epoch FROM (p_first_bid - p_start)) / 60.0;
  IF v_mins < 20 THEN
    RETURN 20;
  ELSIF v_mins < 40 THEN
    RETURN 10;
  ELSIF v_mins < 50 THEN
    RETURN 5;
  END IF;
  RETURN 0;
END;
$$;

CREATE OR REPLACE FUNCTION public.special_auction_visible_clues(p_auction_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  a public.special_auctions%rowtype;
  v_mins numeric := 0;
  v_out jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO a FROM public.special_auctions WHERE id = p_auction_id;
  IF NOT FOUND THEN
    RETURN '[]'::jsonb;
  END IF;

  IF now() >= a.start_time THEN
    v_mins := extract(epoch FROM (now() - a.start_time)) / 60.0;
  ELSE
    RETURN '[]'::jsonb;
  END IF;

  IF a.clue_1 IS NOT NULL AND btrim(a.clue_1) <> '' THEN
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'n', 1, 'at_min', 0, 'discount_pct', 20, 'text', a.clue_1, 'visible', true
    ));
  END IF;
  IF a.clue_2 IS NOT NULL AND btrim(a.clue_2) <> '' THEN
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'n', 2, 'at_min', 20, 'discount_pct', 10, 'text', a.clue_2, 'visible', v_mins >= 20
    ));
  END IF;
  IF a.clue_3 IS NOT NULL AND btrim(a.clue_3) <> '' THEN
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'n', 3, 'at_min', 40, 'discount_pct', 5, 'text', a.clue_3, 'visible', v_mins >= 40
    ));
  END IF;
  IF a.clue_4 IS NOT NULL AND btrim(a.clue_4) <> '' THEN
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'n', 4, 'at_min', 50, 'discount_pct', 0, 'text', a.clue_4, 'visible', v_mins >= 50
    ));
  END IF;

  RETURN v_out;
END;
$$;

-- ---------------------------------------------------------------------------
-- Submit bid — LUB one secret bid; Snap appends a new bid each time (fee later)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.special_auction_submit_bid(
  p_auction_id bigint,
  p_amount numeric
)
RETURNS public.special_auction_bids
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_auction public.special_auctions%rowtype;
  v_club text;
  v_amount numeric;
  v_row public.special_auction_bids%rowtype;
  v_existing bigint;
  v_end timestamptz;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_auction FROM public.special_auctions WHERE id = p_auction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Auction not found'; END IF;
  IF v_auction.status NOT IN ('scheduled', 'active') THEN
    RAISE EXCEPTION 'Auction is not open for owners';
  END IF;

  v_end := public.special_auction_snap_effective_end(v_auction);
  IF now() < v_auction.start_time OR now() >= v_end THEN
    RAISE EXCEPTION 'Auction is not open for bidding';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Bid must be positive'; END IF;

  IF v_auction.auction_type = 'lowest_unique' THEN
    SELECT id INTO v_existing
    FROM public.special_auction_bids
    WHERE auction_id = p_auction_id AND club_id = v_club
    LIMIT 1;
    IF v_existing IS NOT NULL THEN
      RAISE EXCEPTION 'You already submitted your secret bid';
    END IF;
    v_amount := public.round_bid_to_million(p_amount);
    IF v_amount < 1000000 THEN
      RAISE EXCEPTION 'Bid must be at least ₿1,000,000 (rounded to nearest million)';
    END IF;
  ELSE
    v_amount := round(p_amount);
    IF v_amount < 1000000 THEN
      RAISE EXCEPTION 'Bid must be at least ₿1,000,000';
    END IF;
  END IF;

  INSERT INTO public.special_auction_bids (auction_id, club_id, owner_id, bid_amount)
  VALUES (p_auction_id, v_club, auth.uid(), v_amount)
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Activate — for snap, randomise close into final 10 minutes
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.special_auction_activate(p_auction_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.special_auctions%rowtype;
  v_random_end timestamptz;
BEGIN
  IF NOT public.is_gpsl_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;

  SELECT * INTO v_row FROM public.special_auctions WHERE id = p_auction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Auction not found'; END IF;

  UPDATE public.special_auctions
  SET status = 'draft', updated_at = now()
  WHERE status IN ('scheduled', 'active')
    AND id IS DISTINCT FROM p_auction_id;

  IF v_row.auction_type = 'snap' THEN
    -- Ensure 60-minute window from start; random close in minutes 50–60
    v_random_end :=
      v_row.start_time
      + interval '50 minutes'
      + (random() * interval '10 minutes');

    UPDATE public.special_auctions
    SET end_time = v_row.start_time + interval '60 minutes',
        snap_random_end_at = v_random_end,
        snap_bid_fee = coalesce(nullif(snap_bid_fee, 0), 300000),
        status = CASE WHEN now() < start_time THEN 'scheduled' ELSE 'active' END,
        updated_at = now()
    WHERE id = p_auction_id;
  ELSE
    UPDATE public.special_auctions
    SET status = CASE WHEN now() < start_time THEN 'scheduled' ELSE 'active' END,
        updated_at = now()
    WHERE id = p_auction_id;
  END IF;

  BEGIN
    IF to_regprocedure('public.special_auction_notify_scheduled(bigint)') IS NOT NULL THEN
      PERFORM public.special_auction_notify_scheduled(p_auction_id);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'special_auction_notify_scheduled failed: %', SQLERRM;
  END;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Award prize — player assign + pending options; cash credit
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
  v_squad int;
  v_max int := 28;
BEGIN
  IF p_winner_club IS NULL THEN
    RETURN;
  END IF;

  IF p_auction.prize_type = 'player' AND p_auction.prize_player_id IS NOT NULL THEN
    SELECT count(*)::int INTO v_squad
    FROM public."Players" p
    WHERE p."Contracted_Team" = p_winner_club;

    PERFORM public.player_assign_to_club(
      p_auction.prize_player_id,
      p_winner_club
    );

    -- Remove from auction exclusion pool once awarded
    DELETE FROM public.auction_exclusion_players
    WHERE player_id = p_auction.prize_player_id;

    UPDATE public.special_auctions
    SET winner_prize_pending = true,
        winner_prize_resolved = false,
        updated_at = now()
    WHERE id = p_auction.id;

  ELSIF p_auction.prize_type = 'cash' AND coalesce(p_auction.prize_cash_amount, 0) > 0 THEN
    UPDATE public."Club_Finances"
    SET balance = balance + p_auction.prize_cash_amount
    WHERE club_name = p_winner_club;
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Settle snap — multi-bid fees + discount on winning bid purchase
-- ---------------------------------------------------------------------------

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
  v_win_bid_id bigint;
  v_first_bid timestamptz;
  v_discount numeric := 0;
  v_purchase numeric := 0;
  v_club text;
  v_bid_count int;
  v_fee_total numeric;
  v_fee_charge numeric;
  v_unit_fee numeric;
  v_balance numeric;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_auction FROM public.special_auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Auction not found'; END IF;

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

    UPDATE public.special_auction_bids
    SET fee_charged = v_win_amount, is_winner = (club_id = v_win_club)
    WHERE auction_id = p_auction_id;

    PERFORM public.special_auction_award_prize(v_auction, v_win_club, v_win_amount);
    UPDATE public.special_auctions SET status = 'settled', updated_at = now() WHERE id = p_auction_id;
    RETURN;
  END IF;

  -- Snap
  IF v_auction.auction_type <> 'snap' THEN
    RAISE EXCEPTION 'Unknown auction type';
  END IF;

  SELECT b.id, b.club_id, b.bid_amount
  INTO v_win_bid_id, v_win_club, v_win_amount
  FROM public.special_auction_bids b
  WHERE b.auction_id = p_auction_id
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  UPDATE public.special_auction_bids SET is_winner = false WHERE auction_id = p_auction_id;
  IF v_win_club IS NOT NULL THEN
    UPDATE public.special_auction_bids SET is_winner = true WHERE id = v_win_bid_id;

    SELECT min(b.bid_time) INTO v_first_bid
    FROM public.special_auction_bids b
    WHERE b.auction_id = p_auction_id AND b.club_id = v_win_club;

    v_discount := public.special_auction_snap_discount_pct(v_auction.start_time, v_first_bid);
    v_purchase := round(coalesce(v_win_amount, 0) * (1 - v_discount / 100.0));
  END IF;

  v_unit_fee := coalesce(nullif(v_auction.snap_bid_fee, 0), 300000);

  FOR v_club, v_bid_count IN
    SELECT b.club_id, count(*)::int
    FROM public.special_auction_bids b
    WHERE b.auction_id = p_auction_id
    GROUP BY b.club_id
  LOOP
    v_fee_total := v_bid_count * v_unit_fee;
    IF v_club = v_win_club THEN
      v_fee_charge := v_fee_total + coalesce(v_purchase, 0);
    ELSE
      v_fee_charge := round(v_fee_total * 0.25);
    END IF;

    SELECT balance INTO v_balance
    FROM public."Club_Finances"
    WHERE club_name = v_club
    FOR UPDATE;

    IF v_balance IS NOT NULL THEN
      UPDATE public."Club_Finances"
      SET balance = v_balance - v_fee_charge
      WHERE club_name = v_club;
    END IF;

    UPDATE public.special_auction_bids
    SET fee_charged = CASE
      WHEN club_id = v_win_club THEN
        (v_unit_fee)  -- per-row marker; total charged on club finances
      ELSE round(v_unit_fee * 0.25)
    END
    WHERE auction_id = p_auction_id AND club_id = v_club;
  END LOOP;

  -- Store full winner fee total on winning bid row for audit clarity
  IF v_win_bid_id IS NOT NULL THEN
    UPDATE public.special_auction_bids
    SET fee_charged = (
      SELECT count(*)::numeric * v_unit_fee
      FROM public.special_auction_bids
      WHERE auction_id = p_auction_id AND club_id = v_win_club
    ) + coalesce(v_purchase, 0)
    WHERE id = v_win_bid_id;
  END IF;

  UPDATE public.special_auctions
  SET winning_club_id = v_win_club,
      winning_amount = v_win_amount,
      winner_discount_pct = coalesce(v_discount, 0),
      winner_purchase_amount = v_purchase,
      status = 'settled',
      updated_at = now()
  WHERE id = p_auction_id;

  SELECT * INTO v_auction FROM public.special_auctions WHERE id = p_auction_id;
  PERFORM public.special_auction_award_prize(v_auction, v_win_club, v_win_amount);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Winner prize options (player) — 125% release / list at MV
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.special_auction_winner_release_player(
  p_auction_id bigint,
  p_player_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  a public.special_auctions%rowtype;
  v_my_club text := public.my_club_shortname();
  v_pid text := btrim(coalesce(p_player_id, ''));
  v_mv numeric;
  v_credit numeric;
  v_name text;
  v_team text;
BEGIN
  SELECT * INTO a FROM public.special_auctions WHERE id = p_auction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Auction not found'; END IF;
  IF a.status <> 'settled' OR a.prize_type <> 'player' THEN
    RAISE EXCEPTION 'Not a settled player special auction';
  END IF;
  IF a.winning_club_id IS DISTINCT FROM v_my_club AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Only the winning club can resolve the prize';
  END IF;
  IF NOT coalesce(a.winner_prize_pending, false) THEN
    RAISE EXCEPTION 'Prize options are not open for this auction';
  END IF;

  SELECT p."market_value", p."Name", p."Contracted_Team"
  INTO v_mv, v_name, v_team
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Player not found'; END IF;
  IF v_team IS DISTINCT FROM a.winning_club_id THEN
    RAISE EXCEPTION 'Player is not at the winning club';
  END IF;

  v_credit := round(coalesce(v_mv, 0) * 1.25);

  UPDATE public."Players"
  SET "Contracted_Team" = NULL,
      "Season_Signed" = NULL,
      contract_seasons_remaining = NULL,
      contract_wage = NULL
  WHERE "Konami_ID"::text = v_pid;

  UPDATE public."Club_Finances"
  SET balance = balance + v_credit
  WHERE club_name = a.winning_club_id;

  -- Does not consume voluntary / seasonal release quotas
  IF v_pid = a.prize_player_id THEN
    UPDATE public.special_auctions
    SET winner_prize_pending = false,
        winner_prize_resolved = true,
        updated_at = now()
    WHERE id = p_auction_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'player_name', v_name,
    'credit', v_credit,
    'rate', 1.25
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.special_auction_winner_list_prize_player(p_auction_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  a public.special_auctions%rowtype;
  v_my_club text := public.my_club_shortname();
  v_pid text;
  v_mv numeric;
  v_team text;
  v_listing_id bigint;
  v_now timestamptz := now();
  v_end timestamptz := now() + interval '24 hours';
BEGIN
  SELECT * INTO a FROM public.special_auctions WHERE id = p_auction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Auction not found'; END IF;
  IF a.status <> 'settled' OR a.prize_type <> 'player' THEN
    RAISE EXCEPTION 'Not a settled player special auction';
  END IF;
  IF a.winning_club_id IS DISTINCT FROM v_my_club AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Only the winning club can list the prize player';
  END IF;
  IF NOT coalesce(a.winner_prize_pending, false) THEN
    RAISE EXCEPTION 'Prize options are not open';
  END IF;

  v_pid := a.prize_player_id;

  SELECT p."market_value", p."Contracted_Team"
  INTO v_mv, v_team
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND OR v_team IS DISTINCT FROM a.winning_club_id THEN
    RAISE EXCEPTION 'Prize player is not at your club';
  END IF;

  INSERT INTO public."Player_Transfer_Listings" (
    player_id,
    seller_club_id,
    reserve_price,
    market_value,
    status,
    listing_type,
    created_at,
    start_time,
    end_time,
    initial_end_time
  )
  VALUES (
    v_pid,
    a.winning_club_id,
    coalesce(v_mv, 0),
    coalesce(v_mv, 0),
    'Active',
    'standard',
    v_now,
    v_now,
    v_end,
    v_end
  )
  RETURNING id INTO v_listing_id;

  -- Keep pending so unsold prize can still be released at 125%
  RETURN jsonb_build_object(
    'ok', true,
    'listing_id', v_listing_id,
    'player_id', v_pid,
    'asking_price', coalesce(v_mv, 0)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.special_auction_winner_keep_prize(p_auction_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  a public.special_auctions%rowtype;
  v_club text := public.my_club_shortname();
BEGIN
  SELECT * INTO a FROM public.special_auctions WHERE id = p_auction_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Auction not found'; END IF;
  IF a.winning_club_id IS DISTINCT FROM v_club AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Only the winning club can confirm';
  END IF;
  UPDATE public.special_auctions
  SET winner_prize_pending = false,
      winner_prize_resolved = true,
      updated_at = now()
  WHERE id = p_auction_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

DROP POLICY IF EXISTS special_auction_bids_insert_own ON public.special_auction_bids;
CREATE POLICY special_auction_bids_insert_own ON public.special_auction_bids
  FOR INSERT TO authenticated
  WITH CHECK (
    club_id = public.my_club_shortname()
    AND owner_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM public.special_auctions a
      WHERE a.id = auction_id
        AND a.status IN ('scheduled', 'active')
        AND now() >= a.start_time
        AND now() < coalesce(a.snap_random_end_at, a.end_time)
    )
  );

GRANT EXECUTE ON FUNCTION public.special_auction_submit_bid(bigint, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_activate(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_settle(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_visible_clues(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_winner_release_player(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_winner_list_prize_player(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_winner_keep_prize(bigint) TO authenticated;
