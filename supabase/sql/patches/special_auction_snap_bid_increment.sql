-- =============================================================================
-- Special auction snap — require ₿500,000 above the current highest bid
--
-- Bug: snap submit only checked ≥ ₿1,000,000, so owners could match the high.
-- Lowest-unique auctions are unchanged (secret bids; duplicates are intentional).
--
-- Also: snap is an open multi-bid auction. The old UNIQUE (auction_id, club_id)
-- must be dropped so each raise inserts a new bid row (and charges another fee).
--
-- Run once in Supabase SQL Editor (ideally after special_auction_snap_v2.sql).
-- Safe re-run.
-- =============================================================================

-- Open snap auctions: multiple bids per club (LUB still limited in the RPC)
ALTER TABLE public.special_auction_bids
  DROP CONSTRAINT IF EXISTS special_auction_bids_auction_id_club_id_key;

CREATE INDEX IF NOT EXISTS special_auction_bids_auction_club_idx
  ON public.special_auction_bids (auction_id, club_id, bid_time);

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
    v_amount := public.round_bid_to_million(p_amount);
    IF v_amount < 1000000 THEN
      RAISE EXCEPTION 'Bid must be at least ₿1,000,000 (rounded to nearest million)';
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
  'LUB: one secret bid (nearest ₿1m). Snap: each bid must be ≥ ₿1m and at least ₿500k above the current high.';
