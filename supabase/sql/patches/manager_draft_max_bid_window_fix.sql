-- =============================================================================
-- Fix: manager_draft_set_max_bid 400 — v_gs.draft_bidding_open
-- =============================================================================
-- draft_bidding_open is a VIEW column on global_settings_public, not a column on
-- global_settings. draft_auction_window_bounds() selected into
-- global_settings%rowtype then read v_gs.draft_bidding_open → 400 on max bid.
--
-- Also: after draft_schedules_per_type, manager draft has its own start/finish.
-- Max-bid helpers were still using the PLAYER draft window, so auto-bids / min
-- next bid could miss real manager bids.
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

-- Player draft window (table columns only — no view fields)
CREATE OR REPLACE FUNCTION public.draft_auction_window_bounds()
RETURNS TABLE (
  draft_enabled boolean,
  draft_start timestamptz,
  draft_cutoff timestamptz,
  draft_window_end timestamptz,
  bidding_open boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_enabled boolean;
  v_start timestamptz;
  v_finish timestamptz;
BEGIN
  SELECT
    coalesce(gs.draft_auction_enabled, false),
    gs.draft_auction_start_time,
    gs.draft_random_finish_time
  INTO v_enabled, v_start, v_finish
  FROM public.global_settings gs
  WHERE gs.id = 1;

  draft_enabled := v_enabled;
  draft_start := v_start;

  IF v_start IS NULL THEN
    draft_cutoff := NULL;
    draft_window_end := NULL;
    bidding_open := false;
    RETURN NEXT;
    RETURN;
  END IF;

  draft_cutoff := v_start + interval '23 hours';
  draft_window_end := coalesce(
    v_finish,
    v_start + interval '23 hours 59 minutes 59 seconds'
  );
  bidding_open := v_enabled
    AND v_finish IS NOT NULL
    AND now() >= v_start
    AND now() < v_finish;
  RETURN NEXT;
END;
$function$;

-- Manager draft window (separate clock)
CREATE OR REPLACE FUNCTION public.manager_draft_auction_window_bounds()
RETURNS TABLE (
  draft_enabled boolean,
  draft_start timestamptz,
  draft_cutoff timestamptz,
  draft_window_end timestamptz,
  bidding_open boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_enabled boolean;
  v_start timestamptz;
  v_finish timestamptz;
BEGIN
  SELECT
    coalesce(gs.manager_draft_auction_enabled, false),
    coalesce(gs.manager_draft_auction_start_time, gs.draft_auction_start_time),
    coalesce(gs.manager_draft_random_finish_time, gs.draft_random_finish_time)
  INTO v_enabled, v_start, v_finish
  FROM public.global_settings gs
  WHERE gs.id = 1;

  draft_enabled := v_enabled;
  draft_start := v_start;

  IF v_start IS NULL THEN
    draft_cutoff := NULL;
    draft_window_end := NULL;
    bidding_open := false;
    RETURN NEXT;
    RETURN;
  END IF;

  draft_cutoff := v_start + interval '23 hours';
  draft_window_end := coalesce(
    v_finish,
    v_start + interval '23 hours 59 minutes 59 seconds'
  );
  bidding_open := v_enabled
    AND now() >= v_start
    AND now() < draft_window_end;
  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_draft_bidding_open_now()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(wb.bidding_open, false)
  FROM public.manager_draft_auction_window_bounds() wb
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.manager_draft_min_next_bid(p_manager_id bigint)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_high numeric;
  v_mv numeric;
  v_bounds record;
BEGIN
  SELECT * INTO v_bounds FROM public.manager_draft_auction_window_bounds();
  SELECT m.market_value INTO v_mv
  FROM public."Managers" m WHERE m.id = p_manager_id;

  SELECT max(b.bid_amount) INTO v_high
  FROM public."Manager_Transfer_Bids" b
  WHERE b.manager_id = p_manager_id
    AND b.is_direct = true
    AND v_bounds.draft_start IS NOT NULL
    AND b.bid_time >= v_bounds.draft_start
    AND b.bid_time < v_bounds.draft_window_end;

  IF v_high IS NULL THEN
    RETURN coalesce(v_mv, 0);
  END IF;
  RETURN greatest(coalesce(v_mv, 0), v_high + 500000);
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
BEGIN
  IF NOT public.manager_draft_bidding_open_now() THEN
    RETURN jsonb_build_object('ok', false, 'skipped', 'not_open');
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
    RETURN jsonb_build_object('ok', false, 'skipped', 'no_listing');
  END IF;

  IF v_leader IS NOT DISTINCT FROM p_club_short_name THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'already_leading');
  END IF;

  v_min := public.manager_draft_min_next_bid(p_manager_id);
  IF p_amount < v_min THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'below_min');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public."Manager_Transfer_Listings" l
    WHERE l.listing_type = 'draft'
      AND l.status = 'Active'
      AND l.current_highest_bidder = p_club_short_name
      AND l.manager_id <> p_manager_id
  ) THEN
    RETURN jsonb_build_object('ok', false, 'skipped', 'leading_other');
  END IF;

  INSERT INTO public."Manager_Transfer_Bids" (
    listing_id, manager_id, bidder_club_id, bid_amount,
    is_direct, is_first_draft_bid, is_draft_join, draft_join_consumed, bid_time
  )
  VALUES (
    v_listing_id, p_manager_id, p_club_short_name, p_amount,
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

  UPDATE public."Manager_Transfer_Listings"
  SET current_highest_bid = p_amount,
      current_highest_bidder = p_club_short_name
  WHERE id = v_listing_id;

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
    RETURN 0;
  END IF;

  LOOP
    v_i := v_i + 1;
    EXIT WHEN v_i > 40;

    SELECT l.current_highest_bidder INTO v_leader
    FROM public."Manager_Transfer_Listings" l
    WHERE l.manager_id = p_manager_id
      AND l.listing_type = 'draft'
      AND l.status = 'Active'
    LIMIT 1;

    v_min := public.manager_draft_min_next_bid(p_manager_id);

    SELECT m.club_short_name, m.max_amount
    INTO v_club, v_max
    FROM public.manager_draft_max_bids m
    WHERE m.manager_id = p_manager_id
      AND m.max_amount >= v_min
      AND m.club_short_name IS DISTINCT FROM v_leader
      AND NOT EXISTS (
        SELECT 1 FROM public."Manager_Transfer_Listings" l2
        WHERE l2.listing_type = 'draft'
          AND l2.status = 'Active'
          AND l2.current_highest_bidder = m.club_short_name
          AND l2.manager_id <> p_manager_id
      )
    ORDER BY m.max_amount DESC, m.updated_at ASC
    LIMIT 1;

    EXIT WHEN v_club IS NULL;
    EXIT WHEN v_min > v_max;

    BEGIN
      v_result := public.manager_draft_place_auto_bid(v_club, p_manager_id, v_min);
    EXCEPTION WHEN OTHERS THEN
      EXIT;
    END;
    EXIT WHEN coalesce(v_result->>'skipped', '') <> '';
    EXIT WHEN coalesce((v_result->>'ok')::boolean, false) IS NOT TRUE;
    v_placed := v_placed + 1;
    v_club := NULL;
  END LOOP;

  RETURN v_placed;
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_draft_set_max_bid(
  p_manager_id bigint,
  p_max_amount numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_max numeric := p_max_amount;
  v_min numeric;
  v_leader text;
  v_placed jsonb := NULL;
  v_auto int := 0;
BEGIN
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;
  IF v_max IS NULL OR v_max <= 0 THEN
    RAISE EXCEPTION 'Max bid amount is required';
  END IF;

  IF NOT public.manager_draft_bidding_open_now() THEN
    RAISE EXCEPTION 'Manager draft bidding is not open';
  END IF;

  INSERT INTO public.manager_draft_max_bids (club_short_name, manager_id, max_amount, updated_at)
  VALUES (v_club, p_manager_id, v_max, now())
  ON CONFLICT (club_short_name, manager_id) DO UPDATE
  SET max_amount = excluded.max_amount, updated_at = now();

  SELECT l.current_highest_bidder INTO v_leader
  FROM public."Manager_Transfer_Listings" l
  WHERE l.manager_id = p_manager_id
    AND l.listing_type = 'draft'
    AND l.status = 'Active'
  LIMIT 1;

  IF v_leader IS DISTINCT FROM v_club THEN
    v_min := public.manager_draft_min_next_bid(p_manager_id);
    IF v_min <= v_max THEN
      IF v_leader IS NULL AND NOT EXISTS (
        SELECT 1 FROM public."Manager_Transfer_Listings" l
        WHERE l.manager_id = p_manager_id AND l.listing_type = 'draft' AND l.status = 'Active'
      ) THEN
        PERFORM public.manager_draft_ensure_listing(p_manager_id);
      END IF;
      v_placed := public.manager_draft_place_auto_bid(v_club, p_manager_id, v_min);
    END IF;
  END IF;

  v_auto := public.manager_draft_resolve_max_bids(p_manager_id);

  RETURN jsonb_build_object(
    'ok', true,
    'manager_id', p_manager_id,
    'max_amount', v_max,
    'initial_auto_bid', v_placed,
    'proxy_bids_placed', v_auto
  );
END;
$function$;

-- Repair: sync listing high bid from window bids (fixes empty UI after failed max-bid)
CREATE OR REPLACE FUNCTION public.admin_repair_manager_draft_listing_high_bids()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_bounds record;
  v_row record;
  v_updated int := 0;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_bounds FROM public.manager_draft_auction_window_bounds();

  FOR v_row IN
    SELECT
      l.id AS listing_id,
      b.bid_amount,
      b.bidder_club_id
    FROM public."Manager_Transfer_Listings" l
    JOIN LATERAL (
      SELECT b2.bid_amount, b2.bidder_club_id
      FROM public."Manager_Transfer_Bids" b2
      WHERE b2.manager_id = l.manager_id
        AND b2.is_direct = true
        AND (
          v_bounds.draft_start IS NULL
          OR (
            b2.bid_time >= v_bounds.draft_start
            AND b2.bid_time < v_bounds.draft_window_end
          )
        )
      ORDER BY b2.bid_amount DESC, b2.bid_time ASC
      LIMIT 1
    ) b ON true
    WHERE l.listing_type = 'draft'
      AND l.status = 'Active'
      AND (
        l.current_highest_bid IS DISTINCT FROM b.bid_amount
        OR l.current_highest_bidder IS DISTINCT FROM b.bidder_club_id
      )
  LOOP
    UPDATE public."Manager_Transfer_Listings"
    SET current_highest_bid = v_row.bid_amount,
        current_highest_bidder = v_row.bidder_club_id
    WHERE id = v_row.listing_id;
    v_updated := v_updated + 1;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'listings_synced', v_updated);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.draft_auction_window_bounds() TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_draft_auction_window_bounds() TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_draft_bidding_open_now() TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_draft_min_next_bid(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_draft_set_max_bid(bigint, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_repair_manager_draft_listing_high_bids() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Sync any listings that have bids but blank high-bid columns
SELECT public.admin_repair_manager_draft_listing_high_bids();
