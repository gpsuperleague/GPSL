-- =============================================================================
-- Special auction LUB: ₿1,000 bid increments + anonymous participation stats
--
-- 1) LUB bids round to nearest ₿1,000 (min ₿1,000). Snap unchanged.
-- 2) special_auction_participation_stats — owners_total / clubs_bid / pct
--    (no club ids, no bid amounts).
--
-- Safe re-run. Run after special_auction_snap_bid_increment.sql.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.round_bid_to_thousand(p_amount numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_amount IS NULL THEN NULL
    ELSE round(p_amount / 1000.0) * 1000
  END;
$$;

COMMENT ON FUNCTION public.round_bid_to_thousand(numeric) IS
  'Round a bid amount to the nearest ₿1,000 (LUB).';

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
  v_high numeric;
  v_min numeric;
BEGIN
  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT * INTO v_auction
  FROM public.special_auctions
  WHERE id = p_auction_id
  FOR UPDATE;

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
    v_amount := public.round_bid_to_thousand(p_amount);
    IF v_amount < 1000 THEN
      RAISE EXCEPTION 'Bid must be at least ₿1,000 (rounded to nearest ₿1,000)';
    END IF;
  ELSE
    v_amount := round(p_amount);
    SELECT coalesce(max(b.bid_amount), 0)
    INTO v_high
    FROM public.special_auction_bids b
    WHERE b.auction_id = p_auction_id;

    IF v_high <= 0 THEN
      v_min := 1000000;
    ELSE
      v_min := v_high + 500000;
    END IF;

    IF v_amount < v_min THEN
      RAISE EXCEPTION 'Bid must be at least ₿%', to_char(v_min, 'FM999,999,999,999');
    END IF;
  END IF;

  INSERT INTO public.special_auction_bids (auction_id, club_id, owner_id, bid_amount)
  VALUES (p_auction_id, v_club, auth.uid(), v_amount)
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$function$;

COMMENT ON FUNCTION public.special_auction_submit_bid(bigint, numeric) IS
  'LUB: one secret bid (nearest ₿1k, min ₿1k). Snap: each bid ≥ ₿1m and ≥ high + ₿500k.';

CREATE OR REPLACE FUNCTION public.special_auction_participation_stats(p_auction_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_auction public.special_auctions%rowtype;
  v_owners int := 0;
  v_bid int := 0;
  v_pct numeric := 0;
BEGIN
  IF p_auction_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'auction_id required');
  END IF;

  SELECT * INTO v_auction
  FROM public.special_auctions
  WHERE id = p_auction_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not found');
  END IF;

  -- Owners = clubs with a linked owner (exclude system clubs)
  SELECT count(*)::int INTO v_owners
  FROM public."Clubs" c
  WHERE c.owner_id IS NOT NULL
    AND coalesce(c."ShortName", '') NOT IN ('FOREIGN', 'GPDB');

  SELECT count(DISTINCT b.club_id)::int INTO v_bid
  FROM public.special_auction_bids b
  WHERE b.auction_id = p_auction_id;

  IF v_owners > 0 THEN
    v_pct := round((100.0 * v_bid) / v_owners, 1);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'auction_id', p_auction_id,
    'auction_type', v_auction.auction_type,
    'status', v_auction.status,
    'owners_total', coalesce(v_owners, 0),
    'clubs_bid', coalesce(v_bid, 0),
    'pct', coalesce(v_pct, 0)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.round_bid_to_thousand(numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_submit_bid(bigint, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.special_auction_participation_stats(bigint) TO authenticated;

COMMENT ON FUNCTION public.special_auction_participation_stats(bigint) IS
  'Anonymous participation: owned-club count vs distinct bidding clubs (no amounts).';

NOTIFY pgrst, 'reload schema';
