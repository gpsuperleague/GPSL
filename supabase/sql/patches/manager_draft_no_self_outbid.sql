-- =============================================================================
-- Fix: manager draft max-bid auto-outbids itself (+500k)
-- =============================================================================
-- Flow bug:
--   1) place_auto_bid INSERTS ₿MV bid
--   2) AFTER INSERT trigger runs resolve_max_bids
--   3) listing.current_highest_bidder still NULL (UPDATE is after INSERT)
--   4) resolve thinks leader ≠ club → places MV+500k for the same club
--
-- Fix:
--   A) Suppress resolve trigger while placing an auto-bid
--   B) Resolve leader from bid rows (not stale listing column)
--   C) already_leading also checks latest bid club
--
-- Optional cleanup at bottom removes lone self-raise (+500k) when no rival bid.
-- Run in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.auction_max_bid_end_resolve()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config('gpsl.max_bid_resolving', '', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.manager_draft_current_leader(p_manager_id bigint)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_leader text;
  v_bounds record;
BEGIN
  SELECT * INTO v_bounds FROM public.manager_draft_auction_window_bounds();

  SELECT b.bidder_club_id INTO v_leader
  FROM public."Manager_Transfer_Bids" b
  WHERE b.manager_id = p_manager_id
    AND b.is_direct = true
    AND (
      v_bounds.draft_start IS NULL
      OR (
        b.bid_time >= v_bounds.draft_start
        AND b.bid_time < v_bounds.draft_window_end
      )
    )
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  IF v_leader IS NOT NULL THEN
    RETURN v_leader;
  END IF;

  SELECT l.current_highest_bidder INTO v_leader
  FROM public."Manager_Transfer_Listings" l
  WHERE l.manager_id = p_manager_id
    AND l.listing_type = 'draft'
    AND l.status = 'Active'
  ORDER BY l.id
  LIMIT 1;

  RETURN nullif(btrim(v_leader), '');
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_draft_place_auto_bid(
  p_club_short_name text,
  p_manager_id bigint,
  p_amount numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing_id bigint;
  v_leader text;
  v_min numeric;
  v_club text := upper(btrim(p_club_short_name));
  v_clear_flag boolean := false;
BEGIN
  IF NOT public.manager_draft_bidding_open_now() THEN
    RETURN jsonb_build_object('ok', false, 'skipped', 'not_open');
  END IF;

  -- Prevent AFTER INSERT resolve from re-entering before listing is updated
  IF NOT public.auction_max_bid_resolving() THEN
    PERFORM public.auction_max_bid_begin_resolve();
    v_clear_flag := true;
  END IF;

  SELECT l.id, l.current_highest_bidder INTO v_listing_id, v_leader
  FROM public."Manager_Transfer_Listings" l
  WHERE l.manager_id = p_manager_id
    AND l.listing_type = 'draft'
    AND l.status = 'Active'
  ORDER BY l.id
  LIMIT 1
  FOR UPDATE;

  IF v_listing_id IS NULL THEN
    IF v_clear_flag THEN
      PERFORM public.auction_max_bid_end_resolve();
    END IF;
    RETURN jsonb_build_object('ok', false, 'skipped', 'no_listing');
  END IF;

  v_leader := coalesce(
    public.manager_draft_current_leader(p_manager_id),
    nullif(btrim(v_leader), '')
  );

  IF upper(btrim(coalesce(v_leader, ''))) = v_club THEN
    IF v_clear_flag THEN
      PERFORM public.auction_max_bid_end_resolve();
    END IF;
    RETURN jsonb_build_object('ok', true, 'skipped', 'already_leading');
  END IF;

  v_min := public.manager_draft_min_next_bid(p_manager_id);
  IF p_amount < v_min THEN
    IF v_clear_flag THEN
      PERFORM public.auction_max_bid_end_resolve();
    END IF;
    RETURN jsonb_build_object('ok', true, 'skipped', 'below_min');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public."Manager_Transfer_Listings" l
    WHERE l.listing_type = 'draft'
      AND l.status = 'Active'
      AND upper(btrim(l.current_highest_bidder)) = v_club
      AND l.manager_id <> p_manager_id
  ) THEN
    IF v_clear_flag THEN
      PERFORM public.auction_max_bid_end_resolve();
    END IF;
    RETURN jsonb_build_object('ok', false, 'skipped', 'leading_other');
  END IF;

  -- Listing first so any concurrent reader sees the leader
  UPDATE public."Manager_Transfer_Listings"
  SET current_highest_bid = p_amount,
      current_highest_bidder = v_club
  WHERE id = v_listing_id;

  INSERT INTO public."Manager_Transfer_Bids" (
    listing_id, manager_id, bidder_club_id, bid_amount,
    is_direct, is_first_draft_bid, is_draft_join, draft_join_consumed, bid_time
  )
  VALUES (
    v_listing_id, p_manager_id, v_club, p_amount,
    true,
    NOT EXISTS (
      SELECT 1
      FROM public."Manager_Transfer_Bids" b
      CROSS JOIN LATERAL public.manager_draft_auction_window_bounds() wb
      WHERE b.manager_id = p_manager_id
        AND b.is_direct = true
        AND wb.draft_start IS NOT NULL
        AND b.bid_time >= wb.draft_start
        AND b.bid_time < wb.draft_window_end
    ),
    false, false, now()
  );

  IF v_clear_flag THEN
    PERFORM public.auction_max_bid_end_resolve();
  END IF;

  RETURN jsonb_build_object('ok', true, 'bid_amount', p_amount, 'auto', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_draft_resolve_max_bids(p_manager_id bigint)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_max numeric;
  v_min numeric;
  v_leader text;
  v_placed int := 0;
  v_i int := 0;
  v_result jsonb;
  v_bounds record;
BEGIN
  IF public.auction_max_bid_resolving() THEN
    RETURN 0;
  END IF;
  PERFORM public.auction_max_bid_begin_resolve();

  SELECT * INTO v_bounds FROM public.manager_draft_auction_window_bounds();
  IF NOT coalesce(v_bounds.draft_enabled, false)
     OR NOT coalesce(v_bounds.bidding_open, false)
     OR v_bounds.draft_start IS NULL
     OR now() < v_bounds.draft_start
     OR now() >= v_bounds.draft_window_end THEN
    PERFORM public.auction_max_bid_end_resolve();
    RETURN 0;
  END IF;

  LOOP
    v_i := v_i + 1;
    EXIT WHEN v_i > 40;

    v_leader := public.manager_draft_current_leader(p_manager_id);
    v_min := public.manager_draft_min_next_bid(p_manager_id);

    SELECT m.club_short_name, m.max_amount
    INTO v_club, v_max
    FROM public.manager_draft_max_bids m
    WHERE m.manager_id = p_manager_id
      AND m.max_amount >= v_min
      AND upper(btrim(m.club_short_name)) IS DISTINCT FROM upper(btrim(coalesce(v_leader, '')))
      AND NOT EXISTS (
        SELECT 1 FROM public."Manager_Transfer_Listings" l2
        WHERE l2.listing_type = 'draft'
          AND l2.status = 'Active'
          AND upper(btrim(l2.current_highest_bidder)) = upper(btrim(m.club_short_name))
          AND l2.manager_id <> p_manager_id
      )
    ORDER BY m.max_amount DESC, m.updated_at ASC
    LIMIT 1;

    EXIT WHEN v_club IS NULL;
    EXIT WHEN v_min > v_max;

    BEGIN
      -- Nested place_auto_bid sees resolving=1 and will not clear our flag
      v_result := public.manager_draft_place_auto_bid(v_club, p_manager_id, v_min);
    EXCEPTION WHEN OTHERS THEN
      EXIT;
    END;
    EXIT WHEN coalesce(v_result->>'skipped', '') <> '';
    EXIT WHEN coalesce((v_result->>'ok')::boolean, false) IS NOT TRUE;
    v_placed := v_placed + 1;
    v_club := NULL;
  END LOOP;

  PERFORM public.auction_max_bid_end_resolve();
  RETURN v_placed;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.auction_max_bid_end_resolve() TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_draft_current_leader(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_draft_place_auto_bid(text, bigint, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_draft_resolve_max_bids(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Cleanup: lone self-raise of exactly +₿500k with no rival bidder
-- (e.g. BAR 43m then 43.5m on an otherwise empty auction)
-- ---------------------------------------------------------------------------
DO $cleanup$
DECLARE
  v_row record;
  v_prev numeric;
  v_prev_club text;
  v_removed int := 0;
BEGIN
  FOR v_row IN
    SELECT
      l.id AS listing_id,
      l.manager_id,
      l.current_highest_bid,
      l.current_highest_bidder,
      b.id AS bid_id,
      b.bid_amount,
      b.bidder_club_id
    FROM public."Manager_Transfer_Listings" l
    JOIN public."Manager_Transfer_Bids" b
      ON b.listing_id = l.id
     AND b.is_direct = true
    WHERE l.listing_type = 'draft'
      AND l.status = 'Active'
      AND l.current_highest_bidder IS NOT NULL
      AND b.bidder_club_id = l.current_highest_bidder
      AND b.bid_amount = l.current_highest_bid
  LOOP
    SELECT b2.bid_amount, b2.bidder_club_id
    INTO v_prev, v_prev_club
    FROM public."Manager_Transfer_Bids" b2
    WHERE b2.listing_id = v_row.listing_id
      AND b2.is_direct = true
      AND b2.id <> v_row.bid_id
    ORDER BY b2.bid_amount DESC, b2.bid_time ASC
    LIMIT 1;

    -- Only strip when previous bid is same club and exactly 500k below
    IF v_prev_club IS NOT NULL
       AND v_prev_club = v_row.bidder_club_id
       AND v_row.bid_amount = v_prev + 500000
       AND NOT EXISTS (
         SELECT 1
         FROM public."Manager_Transfer_Bids" b3
         WHERE b3.listing_id = v_row.listing_id
           AND b3.is_direct = true
           AND b3.bidder_club_id IS DISTINCT FROM v_row.bidder_club_id
       ) THEN
      DELETE FROM public."Manager_Transfer_Bids" WHERE id = v_row.bid_id;
      UPDATE public."Manager_Transfer_Listings"
      SET current_highest_bid = v_prev,
          current_highest_bidder = v_prev_club
      WHERE id = v_row.listing_id;
      v_removed := v_removed + 1;
      RAISE NOTICE 'Removed self-outbid % → % on listing % (manager %)',
        v_row.bid_amount, v_prev, v_row.listing_id, v_row.manager_id;
    END IF;
  END LOOP;

  RAISE NOTICE 'Self-outbid cleanup removed % bid(s)', v_removed;
END;
$cleanup$;
