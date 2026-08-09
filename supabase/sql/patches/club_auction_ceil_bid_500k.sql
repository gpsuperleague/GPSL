-- =============================================================================
-- Club auction bids: always round UP to nearest ₿500,000
--
-- Stadium cost = capacity × ₿1,500 can land off the 500k grid (e.g. 32,250,000).
-- Old path used round_bid_to_million (nearest ₿1m), which could prefill / snap
-- BELOW the true minimum. Auto-bid then had to bump +1m as a workaround.
--
-- Run in Supabase SQL Editor after club_auction.sql + auction_max_bids.sql.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.ceil_bid_to_half_million(p_amount numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_amount IS NULL OR p_amount <= 0 THEN NULL
    ELSE ceil(p_amount / 500000.0) * 500000
  END;
$$;

COMMENT ON FUNCTION public.ceil_bid_to_half_million(numeric) IS
  'Round bid amounts UP to the nearest ₿500,000 (club auction step).';

CREATE OR REPLACE FUNCTION public.club_auction_min_next_bid(p_listing_id bigint)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Club_Auction_Listings"%rowtype;
  v_raw numeric;
BEGIN
  SELECT * INTO v_listing
  FROM public."Club_Auction_Listings"
  WHERE id = p_listing_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_listing.current_highest_bid IS NULL THEN
    v_raw := v_listing.opening_bid;
  ELSE
    v_raw := greatest(
      v_listing.opening_bid,
      v_listing.current_highest_bid + public.club_auction_bid_increment()
    );
  END IF;

  RETURN public.ceil_bid_to_half_million(v_raw);
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_auction_place_bid_internal(
  p_owner_id uuid,
  p_club_short_name text,
  p_amount numeric,
  p_is_auto boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_short text := upper(trim(p_club_short_name));
  v_amount numeric;
  v_listing public."Club_Auction_Listings"%rowtype;
  v_registry public.gpsl_owner_registry%rowtype;
  v_min numeric;
  v_budget numeric;
  v_other_club text;
  v_bid_id bigint;
BEGIN
  IF NOT public.club_auction_bidding_open_now() THEN
    RAISE EXCEPTION 'Club auction bidding is not open';
  END IF;

  SELECT * INTO v_registry
  FROM public.gpsl_owner_registry
  WHERE owner_id = p_owner_id
  FOR UPDATE;

  IF NOT FOUND OR v_registry.status IS DISTINCT FROM 'awaiting_club_auction' THEN
    RAISE EXCEPTION 'You are not registered for the club auction';
  END IF;

  IF nullif(btrim(coalesce(v_registry.owner_tag, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Set your owner tag on awaiting_club.html before bidding';
  END IF;

  IF EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = p_owner_id) THEN
    RAISE EXCEPTION 'You already have a club';
  END IF;

  v_amount := public.ceil_bid_to_half_million(p_amount);
  IF v_amount IS NULL OR v_amount <= 0 THEN
    RAISE EXCEPTION 'Bid amount is required';
  END IF;

  v_budget := coalesce(v_registry.pending_starting_balance, 0);
  IF v_amount > v_budget THEN
    RAISE EXCEPTION 'Bid exceeds your starting budget (₿%)', to_char(v_budget, 'FM999,999,999,999');
  END IF;

  SELECT l.club_short_name INTO v_other_club
  FROM public."Club_Auction_Listings" l
  WHERE l.status = 'Active'
    AND l.current_highest_bidder = p_owner_id
    AND l.club_short_name <> v_short
  LIMIT 1;

  IF v_other_club IS NOT NULL THEN
    RAISE EXCEPTION
      'You may only hold the highest bid on one club at a time (currently leading on %)',
      v_other_club;
  END IF;

  SELECT * INTO v_listing
  FROM public."Club_Auction_Listings"
  WHERE club_short_name = v_short
    AND status = 'Active'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No active club auction listing for %', v_short;
  END IF;

  IF p_is_auto AND v_listing.current_highest_bidder = p_owner_id THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'already_leading');
  END IF;

  v_min := public.club_auction_min_next_bid(v_listing.id);
  IF v_amount < v_min THEN
    IF p_is_auto THEN
      RETURN jsonb_build_object('ok', true, 'skipped', 'below_min');
    END IF;
    RAISE EXCEPTION 'Minimum bid is ₿%', to_char(v_min, 'FM999,999,999,999');
  END IF;

  IF v_listing.current_highest_bidder = p_owner_id
     AND v_amount <= coalesce(v_listing.current_highest_bid, 0) THEN
    RAISE EXCEPTION 'Raise your bid above ₿%',
      to_char(coalesce(v_listing.current_highest_bid, 0), 'FM999,999,999,999');
  END IF;

  INSERT INTO public."Club_Auction_Bids" (
    listing_id, club_short_name, bidder_owner_id, bid_amount, bid_time
  )
  VALUES (v_listing.id, v_short, p_owner_id, v_amount, now())
  RETURNING id INTO v_bid_id;

  UPDATE public."Club_Auction_Listings"
  SET current_highest_bid = v_amount,
      current_highest_bidder = p_owner_id,
      updated_at = now()
  WHERE id = v_listing.id;

  RETURN jsonb_build_object(
    'ok', true,
    'bid_id', v_bid_id,
    'listing_id', v_listing.id,
    'club_short_name', v_short,
    'bid_amount', v_amount,
    'auto', p_is_auto,
    'min_next_bid', public.ceil_bid_to_half_million(
      v_amount + public.club_auction_bid_increment()
    ),
    'remaining_budget', v_budget - v_amount
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_auction_resolve_max_bids(p_club_short_name text)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_short text := upper(trim(p_club_short_name));
  v_listing public."Club_Auction_Listings"%rowtype;
  v_owner uuid;
  v_max numeric;
  v_min numeric;
  v_amount numeric;
  v_budget numeric;
  v_placed int := 0;
  v_i int := 0;
  v_result jsonb;
BEGIN
  IF public.auction_max_bid_resolving() THEN
    RETURN 0;
  END IF;
  PERFORM public.auction_max_bid_begin_resolve();

  IF NOT public.club_auction_bidding_open_now() THEN
    RETURN 0;
  END IF;

  LOOP
    v_i := v_i + 1;
    EXIT WHEN v_i > 40;

    SELECT * INTO v_listing
    FROM public."Club_Auction_Listings"
    WHERE club_short_name = v_short AND status = 'Active'
    FOR UPDATE;

    EXIT WHEN NOT FOUND;

    v_min := public.club_auction_min_next_bid(v_listing.id);

    SELECT m.owner_id, m.max_amount
    INTO v_owner, v_max
    FROM public.club_auction_max_bids m
    JOIN public.gpsl_owner_registry r ON r.owner_id = m.owner_id
    WHERE m.club_short_name = v_short
      AND m.max_amount >= v_min
      AND r.status = 'awaiting_club_auction'
      AND coalesce(r.pending_starting_balance, 0) >= v_min
      AND (v_listing.current_highest_bidder IS DISTINCT FROM m.owner_id)
      AND NOT EXISTS (
        SELECT 1 FROM public."Club_Auction_Listings" l2
        WHERE l2.status = 'Active'
          AND l2.current_highest_bidder = m.owner_id
          AND l2.club_short_name <> v_short
      )
    ORDER BY m.max_amount DESC, m.updated_at ASC
    LIMIT 1;

    EXIT WHEN v_owner IS NULL;

    v_budget := public.club_auction_owner_budget(v_owner);
    v_amount := public.ceil_bid_to_half_million(v_min);
    IF v_amount IS NULL OR v_amount > v_max OR v_amount > v_budget THEN
      EXIT;
    END IF;

    BEGIN
      v_result := public.club_auction_place_bid_internal(v_owner, v_short, v_amount, true);
    EXCEPTION WHEN OTHERS THEN
      EXIT;
    END;
    EXIT WHEN coalesce(v_result->>'skipped', '') <> '';
    v_placed := v_placed + 1;
    v_owner := NULL;
  END LOOP;

  RETURN v_placed;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_auction_set_max_bid(
  p_club_short_name text,
  p_max_amount numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := auth.uid();
  v_short text := upper(trim(p_club_short_name));
  v_max numeric;
  v_budget numeric;
  v_listing public."Club_Auction_Listings"%rowtype;
  v_min numeric;
  v_amount numeric;
  v_placed jsonb := NULL;
  v_auto int := 0;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT public.club_auction_bidding_open_now() THEN
    RAISE EXCEPTION 'Club auction bidding is not open';
  END IF;

  v_max := public.ceil_bid_to_half_million(p_max_amount);
  IF v_max IS NULL OR v_max <= 0 THEN
    RAISE EXCEPTION 'Max bid amount is required';
  END IF;

  v_budget := public.club_auction_owner_budget(v_owner);
  IF v_max > v_budget THEN
    RAISE EXCEPTION 'Max bid exceeds your starting budget (₿%)',
      to_char(v_budget, 'FM999,999,999,999');
  END IF;

  INSERT INTO public.club_auction_max_bids (owner_id, club_short_name, max_amount, updated_at)
  VALUES (v_owner, v_short, v_max, now())
  ON CONFLICT (owner_id, club_short_name) DO UPDATE
  SET max_amount = excluded.max_amount, updated_at = now();

  SELECT * INTO v_listing
  FROM public."Club_Auction_Listings"
  WHERE club_short_name = v_short AND status = 'Active';

  IF FOUND AND v_listing.current_highest_bidder IS DISTINCT FROM v_owner THEN
    v_min := public.club_auction_min_next_bid(v_listing.id);
    v_amount := public.ceil_bid_to_half_million(v_min);
    IF v_amount IS NOT NULL AND v_amount <= v_max AND v_amount <= v_budget THEN
      v_placed := public.club_auction_place_bid_internal(v_owner, v_short, v_amount, true);
    END IF;
  END IF;

  v_auto := public.club_auction_resolve_max_bids(v_short);

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_short,
    'max_amount', v_max,
    'initial_auto_bid', v_placed,
    'proxy_bids_placed', v_auto
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.ceil_bid_to_half_million(numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_min_next_bid(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_set_max_bid(text, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Spot-check: min next bid should already be on the 500k grid
SELECT
  l.club_short_name,
  l.opening_bid,
  public.club_auction_min_next_bid(l.id) AS min_next_bid,
  public.ceil_bid_to_half_million(l.opening_bid) AS opening_ceiled
FROM public."Club_Auction_Listings" l
WHERE l.status = 'Active'
ORDER BY l.prestige_rank NULLS LAST, l.club_short_name
LIMIT 15;
