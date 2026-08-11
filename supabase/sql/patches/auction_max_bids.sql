-- =============================================================================
-- Auction max bids (proxy auto-bid) — club / manager draft / player draft
--
-- Rules:
--   - Owner sets a private max; system auto-bids min-next when outbid by someone else
--   - Never auto-raises while you already lead
--   - Player draft: setting max that would join a thread requires draft credits
--
-- Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.club_auction_max_bids (
  owner_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  club_short_name text NOT NULL,
  max_amount numeric(14, 2) NOT NULL CHECK (max_amount > 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (owner_id, club_short_name)
);

CREATE TABLE IF NOT EXISTS public.manager_draft_max_bids (
  club_short_name text NOT NULL,
  manager_id bigint NOT NULL,
  max_amount numeric(14, 2) NOT NULL CHECK (max_amount > 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (club_short_name, manager_id)
);

CREATE TABLE IF NOT EXISTS public.player_draft_max_bids (
  club_short_name text NOT NULL,
  player_id text NOT NULL,
  max_amount numeric(14, 2) NOT NULL CHECK (max_amount > 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (club_short_name, player_id)
);

CREATE INDEX IF NOT EXISTS club_auction_max_bids_club_idx
  ON public.club_auction_max_bids (club_short_name);
CREATE INDEX IF NOT EXISTS manager_draft_max_bids_mgr_idx
  ON public.manager_draft_max_bids (manager_id);
CREATE INDEX IF NOT EXISTS player_draft_max_bids_player_idx
  ON public.player_draft_max_bids (player_id);

ALTER TABLE public.club_auction_max_bids ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.manager_draft_max_bids ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.player_draft_max_bids ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS club_auction_max_bids_own ON public.club_auction_max_bids;
CREATE POLICY club_auction_max_bids_own ON public.club_auction_max_bids
  FOR ALL TO authenticated
  USING (owner_id = auth.uid())
  WITH CHECK (owner_id = auth.uid());

DROP POLICY IF EXISTS manager_draft_max_bids_own ON public.manager_draft_max_bids;
CREATE POLICY manager_draft_max_bids_own ON public.manager_draft_max_bids
  FOR ALL TO authenticated
  USING (club_short_name = public.my_club_shortname())
  WITH CHECK (club_short_name = public.my_club_shortname());

DROP POLICY IF EXISTS player_draft_max_bids_own ON public.player_draft_max_bids;
CREATE POLICY player_draft_max_bids_own ON public.player_draft_max_bids
  FOR ALL TO authenticated
  USING (club_short_name = public.my_club_shortname())
  WITH CHECK (club_short_name = public.my_club_shortname());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.club_auction_max_bids TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.manager_draft_max_bids TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.player_draft_max_bids TO authenticated;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.auction_max_bid_resolving()
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(nullif(current_setting('gpsl.max_bid_resolving', true), ''), '') = '1';
$$;

CREATE OR REPLACE FUNCTION public.auction_max_bid_begin_resolve()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config('gpsl.max_bid_resolving', '1', true);
END;
$$;

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
  -- draft_bidding_open is VIEW-only (global_settings_public) — never read from %rowtype
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

-- ---------------------------------------------------------------------------
-- CLUB AUCTION
-- ---------------------------------------------------------------------------

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

  v_amount := public.round_bid_to_million(p_amount);
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

  -- Auto-bid never raises while already leading
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
    'min_next_bid', v_amount + public.club_auction_bid_increment(),
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
    v_amount := public.round_bid_to_million(v_min);
    IF v_amount < v_min THEN
      v_amount := v_amount + 1000000;
    END IF;
    IF v_amount > v_max OR v_amount > v_budget THEN
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

CREATE OR REPLACE FUNCTION public.club_auction_place_bid(
  p_club_short_name text,
  p_amount numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := auth.uid();
  v_result jsonb;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  v_result := public.club_auction_place_bid_internal(
    v_owner, p_club_short_name, p_amount, false
  );
  PERFORM public.club_auction_resolve_max_bids(upper(trim(p_club_short_name)));
  RETURN v_result;
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

  v_max := public.round_bid_to_million(p_max_amount);
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
    v_amount := public.round_bid_to_million(v_min);
    IF v_amount < v_min THEN
      v_amount := v_amount + 1000000;
    END IF;
    IF v_amount <= v_max AND v_amount <= v_budget THEN
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

CREATE OR REPLACE FUNCTION public.club_auction_clear_max_bid(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := auth.uid();
  v_short text := upper(trim(p_club_short_name));
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  DELETE FROM public.club_auction_max_bids
  WHERE owner_id = v_owner AND club_short_name = v_short;
  RETURN jsonb_build_object('ok', true, 'cleared', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_auction_get_my_max_bid(p_club_short_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := auth.uid();
  v_row public.club_auction_max_bids%rowtype;
BEGIN
  IF v_owner IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_row
  FROM public.club_auction_max_bids
  WHERE owner_id = v_owner
    AND club_short_name = upper(trim(p_club_short_name));
  IF NOT FOUND THEN
    RETURN jsonb_build_object('max_amount', NULL);
  END IF;
  RETURN jsonb_build_object(
    'max_amount', v_row.max_amount,
    'updated_at', v_row.updated_at
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- MANAGER DRAFT
-- ---------------------------------------------------------------------------

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
  SELECT * INTO v_bounds FROM public.draft_auction_window_bounds();
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
  IF NOT coalesce((SELECT manager_draft_auction_enabled FROM public.global_settings WHERE id = 1), false) THEN
    RETURN jsonb_build_object('ok', false, 'skipped', 'disabled');
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

  -- One-lead rule
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
      CROSS JOIN LATERAL public.draft_auction_window_bounds() wb
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

  SELECT * INTO v_bounds FROM public.draft_auction_window_bounds();
  IF NOT coalesce((SELECT manager_draft_auction_enabled FROM public.global_settings WHERE id = 1), false) THEN
    RETURN 0;
  END IF;
  IF v_bounds.draft_start IS NULL OR now() < v_bounds.draft_start
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

  IF NOT coalesce((SELECT manager_draft_auction_enabled FROM public.global_settings WHERE id = 1), false) THEN
    RAISE EXCEPTION 'Manager draft auction is not enabled';
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
      -- Ensure listing exists for first bid
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

CREATE OR REPLACE FUNCTION public.manager_draft_clear_max_bid(p_manager_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
BEGIN
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;
  DELETE FROM public.manager_draft_max_bids
  WHERE club_short_name = v_club AND manager_id = p_manager_id;
  RETURN jsonb_build_object('ok', true, 'cleared', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.manager_draft_get_my_max_bid(p_manager_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_row public.manager_draft_max_bids%rowtype;
BEGIN
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('max_amount', NULL);
  END IF;
  SELECT * INTO v_row
  FROM public.manager_draft_max_bids
  WHERE club_short_name = v_club AND manager_id = p_manager_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('max_amount', NULL);
  END IF;
  RETURN jsonb_build_object('max_amount', v_row.max_amount, 'updated_at', v_row.updated_at);
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_manager_draft_max_bid_resolve()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF public.auction_max_bid_resolving() THEN
    RETURN NEW;
  END IF;
  IF NEW.manager_id IS NOT NULL AND coalesce(NEW.is_direct, false) THEN
    PERFORM public.manager_draft_resolve_max_bids(NEW.manager_id);
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS manager_transfer_bids_max_bid_resolve ON public."Manager_Transfer_Bids";
CREATE TRIGGER manager_transfer_bids_max_bid_resolve
  AFTER INSERT ON public."Manager_Transfer_Bids"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_manager_draft_max_bid_resolve();

-- ---------------------------------------------------------------------------
-- PLAYER DRAFT
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.player_draft_min_next_bid(p_player_id text)
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
  v_pid text := btrim(p_player_id);
BEGIN
  SELECT * INTO v_bounds FROM public.draft_auction_window_bounds();
  SELECT p.market_value INTO v_mv
  FROM public."Players" p WHERE p."Konami_ID"::text = v_pid;

  SELECT max(b.bid_amount) INTO v_high
  FROM public."Player_Transfer_Bids" b
  WHERE coalesce(b.player_id, b.direct_bid_id::text) = v_pid
    AND b.is_direct = true
    AND b.seller_club_id IS NULL
    AND v_bounds.draft_start IS NOT NULL
    AND b.bid_time >= v_bounds.draft_start
    AND b.bid_time < v_bounds.draft_window_end;

  IF v_high IS NULL THEN
    RETURN coalesce(v_mv, 0);
  END IF;
  RETURN v_high + 500000;
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_draft_club_has_bid(
  p_club_short_name text,
  p_player_id text
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_bounds record;
  v_pid text := btrim(p_player_id);
BEGIN
  SELECT * INTO v_bounds FROM public.draft_auction_window_bounds();
  IF v_bounds.draft_start IS NULL THEN
    RETURN false;
  END IF;
  RETURN EXISTS (
    SELECT 1
    FROM public."Player_Transfer_Bids" b
    WHERE b.bidder_club_id = p_club_short_name
      AND coalesce(b.player_id, b.direct_bid_id::text) = v_pid
      AND b.is_direct = true
      AND b.seller_club_id IS NULL
      AND b.bid_time >= v_bounds.draft_start
      AND b.bid_time < v_bounds.draft_window_end
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_draft_ensure_listing(p_player_id text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_id bigint;
  v_mv numeric;
  v_start timestamptz;
  v_end timestamptz;
BEGIN
  SELECT l.id INTO v_id
  FROM public."Player_Transfer_Listings" l
  WHERE l.player_id = v_pid
    AND l.listing_type = 'draft'
    AND l.status = 'Active'
  ORDER BY l.id
  LIMIT 1;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  SELECT p.market_value INTO v_mv
  FROM public."Players" p WHERE p."Konami_ID"::text = v_pid;

  SELECT draft_auction_start_time INTO v_start
  FROM public.global_settings WHERE id = 1;

  v_end := coalesce(v_start, now()) + interval '23 hours 50 minutes'
    + (floor(random() * 600)::int || ' seconds')::interval;

  INSERT INTO public."Player_Transfer_Listings" (
    player_id, seller_club_id, reserve_price, listing_type, market_value,
    status, start_time, end_time, initial_end_time, created_at
  )
  VALUES (
    v_pid, NULL, coalesce(v_mv, 0), 'draft', coalesce(v_mv, 0),
    'Active', coalesce(v_start, now()), v_end, v_end, now()
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_draft_place_auto_bid(
  p_club_short_name text,
  p_player_id text,
  p_amount numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
  v_listing_id bigint;
  v_bounds record;
  v_has_bids boolean;
  v_has_mine boolean;
  v_is_first boolean;
  v_is_join boolean;
  v_consume boolean := false;
  v_credits int;
  v_leader text;
  v_min numeric;
BEGIN
  SELECT * INTO v_bounds FROM public.draft_auction_window_bounds();
  IF NOT v_bounds.draft_enabled OR v_bounds.draft_start IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'skipped', 'disabled');
  END IF;
  IF now() < v_bounds.draft_start OR now() >= v_bounds.draft_window_end THEN
    RETURN jsonb_build_object('ok', false, 'skipped', 'window_closed');
  END IF;

  v_min := public.player_draft_min_next_bid(v_pid);
  IF p_amount < v_min THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'below_min');
  END IF;

  SELECT b.bidder_club_id INTO v_leader
  FROM public."Player_Transfer_Bids" b
  WHERE coalesce(b.player_id, b.direct_bid_id::text) = v_pid
    AND b.is_direct = true
    AND b.seller_club_id IS NULL
    AND b.bid_time >= v_bounds.draft_start
    AND b.bid_time < v_bounds.draft_window_end
  ORDER BY b.bid_amount DESC, b.bid_time DESC
  LIMIT 1;

  IF v_leader IS NOT DISTINCT FROM p_club_short_name THEN
    RETURN jsonb_build_object('ok', true, 'skipped', 'already_leading');
  END IF;

  v_has_bids := v_leader IS NOT NULL;
  v_has_mine := public.player_draft_club_has_bid(p_club_short_name, v_pid);

  IF NOT v_has_bids THEN
    IF now() >= v_bounds.draft_cutoff THEN
      RETURN jsonb_build_object('ok', false, 'skipped', 'cutoff');
    END IF;
    v_is_first := true;
    v_is_join := false;
  ELSIF v_has_mine THEN
    v_is_first := false;
    v_is_join := EXISTS (
      SELECT 1 FROM public."Player_Transfer_Bids" b
      WHERE b.bidder_club_id = p_club_short_name
        AND coalesce(b.player_id, b.direct_bid_id::text) = v_pid
        AND b.is_draft_join = true
        AND b.bid_time >= v_bounds.draft_start
    );
  ELSE
    v_is_first := false;
    v_is_join := true;
    v_credits := public.club_draft_auction_credits(
      p_club_short_name,
      v_bounds.draft_start,
      v_bounds.draft_cutoff,
      v_bounds.draft_window_end
    );
    IF v_credits <= 0 THEN
      RETURN jsonb_build_object(
        'ok', false,
        'skipped', 'no_credits',
        'msg', 'Not enough draft credits to join this auction.'
      );
    END IF;
    v_consume := true;
  END IF;

  v_listing_id := public.player_draft_ensure_listing(v_pid);

  -- player_id holds Konami id (text). direct_bid_id is integer legacy — leave NULL.
  INSERT INTO public."Player_Transfer_Bids" (
    listing_id, player_id, direct_bid_id, bidder_club_id, seller_club_id,
    bid_amount, is_direct, is_first_draft_bid, is_draft_join, draft_join_consumed, bid_time
  )
  VALUES (
    v_listing_id, v_pid, NULL, p_club_short_name, NULL,
    p_amount, true, v_is_first, v_is_join, v_consume, now()
  );

  UPDATE public."Player_Transfer_Listings"
  SET current_highest_bid = p_amount,
      current_highest_bidder = p_club_short_name
  WHERE id = v_listing_id;

  RETURN jsonb_build_object('ok', true, 'bid_amount', p_amount, 'auto', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_draft_resolve_max_bids(p_player_id text)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text := btrim(p_player_id);
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

  SELECT * INTO v_bounds FROM public.draft_auction_window_bounds();
  IF NOT v_bounds.draft_enabled OR v_bounds.draft_start IS NULL THEN
    RETURN 0;
  END IF;
  IF now() < v_bounds.draft_start OR now() >= v_bounds.draft_window_end THEN
    RETURN 0;
  END IF;

  LOOP
    v_i := v_i + 1;
    EXIT WHEN v_i > 40;

    SELECT b.bidder_club_id INTO v_leader
    FROM public."Player_Transfer_Bids" b
    WHERE coalesce(b.player_id, b.direct_bid_id::text) = v_pid
      AND b.is_direct = true
      AND b.seller_club_id IS NULL
      AND b.bid_time >= v_bounds.draft_start
      AND b.bid_time < v_bounds.draft_window_end
    ORDER BY b.bid_amount DESC, b.bid_time DESC
    LIMIT 1;

    v_min := public.player_draft_min_next_bid(v_pid);

    SELECT m.club_short_name, m.max_amount
    INTO v_club, v_max
    FROM public.player_draft_max_bids m
    WHERE m.player_id = v_pid
      AND m.max_amount >= v_min
      AND m.club_short_name IS DISTINCT FROM v_leader
      AND (
        v_leader IS NULL
        OR public.player_draft_club_has_bid(m.club_short_name, v_pid)
        OR public.club_draft_auction_credits(
          m.club_short_name,
          v_bounds.draft_start,
          v_bounds.draft_cutoff,
          v_bounds.draft_window_end
        ) > 0
      )
    ORDER BY m.max_amount DESC, m.updated_at ASC
    LIMIT 1;

    EXIT WHEN v_club IS NULL;
    EXIT WHEN v_min > v_max;

    BEGIN
      v_result := public.player_draft_place_auto_bid(v_club, v_pid, v_min);
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

CREATE OR REPLACE FUNCTION public.player_draft_set_max_bid(
  p_player_id text,
  p_max_amount numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_pid text := btrim(p_player_id);
  v_max numeric := p_max_amount;
  v_bounds record;
  v_has_bids boolean;
  v_has_mine boolean;
  v_credits int;
  v_min numeric;
  v_leader text;
  v_placed jsonb := NULL;
  v_auto int := 0;
BEGIN
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;
  IF v_pid IS NULL OR v_pid = '' THEN
    RAISE EXCEPTION 'Player id is required';
  END IF;
  IF v_max IS NULL OR v_max <= 0 THEN
    RAISE EXCEPTION 'Max bid amount is required';
  END IF;

  SELECT * INTO v_bounds FROM public.draft_auction_window_bounds();
  IF NOT v_bounds.draft_enabled THEN
    RAISE EXCEPTION 'Player draft auction is not enabled';
  END IF;
  IF v_bounds.draft_start IS NULL OR now() < v_bounds.draft_start THEN
    RAISE EXCEPTION 'Draft auction has not started yet';
  END IF;
  IF now() >= v_bounds.draft_window_end THEN
    RAISE EXCEPTION 'Draft auction has ended';
  END IF;

  v_has_mine := public.player_draft_club_has_bid(v_club, v_pid);
  v_has_bids := EXISTS (
    SELECT 1 FROM public."Player_Transfer_Bids" b
    WHERE coalesce(b.player_id, b.direct_bid_id::text) = v_pid
      AND b.is_direct = true
      AND b.seller_club_id IS NULL
      AND b.bid_time >= v_bounds.draft_start
      AND b.bid_time < v_bounds.draft_window_end
  );

  -- Joining a thread via max-bid requires credits (same as manual join)
  IF v_has_bids AND NOT v_has_mine THEN
    v_credits := public.club_draft_auction_credits(
      v_club, v_bounds.draft_start, v_bounds.draft_cutoff, v_bounds.draft_window_end
    );
    IF v_credits <= 0 THEN
      RAISE EXCEPTION
        'Not enough draft credits to join this auction. Open a new free agent in GPDB first to earn credits.';
    END IF;
  END IF;

  IF NOT v_has_bids AND now() >= v_bounds.draft_cutoff THEN
    RAISE EXCEPTION 'New draft auctions cannot be opened after the cutoff';
  END IF;

  INSERT INTO public.player_draft_max_bids (club_short_name, player_id, max_amount, updated_at)
  VALUES (v_club, v_pid, v_max, now())
  ON CONFLICT (club_short_name, player_id) DO UPDATE
  SET max_amount = excluded.max_amount, updated_at = now();

  SELECT b.bidder_club_id INTO v_leader
  FROM public."Player_Transfer_Bids" b
  WHERE coalesce(b.player_id, b.direct_bid_id::text) = v_pid
    AND b.is_direct = true
    AND b.seller_club_id IS NULL
    AND b.bid_time >= v_bounds.draft_start
    AND b.bid_time < v_bounds.draft_window_end
  ORDER BY b.bid_amount DESC, b.bid_time DESC
  LIMIT 1;

  IF v_leader IS DISTINCT FROM v_club THEN
    v_min := public.player_draft_min_next_bid(v_pid);
    IF v_min <= v_max THEN
      v_placed := public.player_draft_place_auto_bid(v_club, v_pid, v_min);
      IF coalesce(v_placed->>'skipped', '') = 'no_credits' THEN
        RAISE EXCEPTION '%', coalesce(v_placed->>'msg',
          'Not enough draft credits to join this auction.');
      END IF;
    END IF;
  END IF;

  v_auto := public.player_draft_resolve_max_bids(v_pid);

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'max_amount', v_max,
    'initial_auto_bid', v_placed,
    'proxy_bids_placed', v_auto
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_draft_clear_max_bid(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_pid text := btrim(p_player_id);
BEGIN
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;
  DELETE FROM public.player_draft_max_bids
  WHERE club_short_name = v_club AND player_id = v_pid;
  RETURN jsonb_build_object('ok', true, 'cleared', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.player_draft_get_my_max_bid(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := public.my_club_shortname();
  v_row public.player_draft_max_bids%rowtype;
BEGIN
  IF v_club IS NULL THEN
    RETURN jsonb_build_object('max_amount', NULL);
  END IF;
  SELECT * INTO v_row
  FROM public.player_draft_max_bids
  WHERE club_short_name = v_club AND player_id = btrim(p_player_id);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('max_amount', NULL);
  END IF;
  RETURN jsonb_build_object('max_amount', v_row.max_amount, 'updated_at', v_row.updated_at);
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_player_draft_max_bid_resolve()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pid text;
BEGIN
  IF public.auction_max_bid_resolving() THEN
    RETURN NEW;
  END IF;
  v_pid := coalesce(NEW.player_id, NEW.direct_bid_id::text);
  IF v_pid IS NOT NULL AND coalesce(NEW.is_direct, false) AND NEW.seller_club_id IS NULL THEN
    PERFORM public.player_draft_resolve_max_bids(v_pid);
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_bids_max_bid_resolve ON public."Player_Transfer_Bids";
CREATE TRIGGER player_transfer_bids_max_bid_resolve
  AFTER INSERT ON public."Player_Transfer_Bids"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_player_draft_max_bid_resolve();

-- Grants
GRANT EXECUTE ON FUNCTION public.club_auction_place_bid(text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_set_max_bid(text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_clear_max_bid(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_get_my_max_bid(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_draft_set_max_bid(bigint, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_draft_clear_max_bid(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_draft_get_my_max_bid(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_draft_set_max_bid(text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_draft_clear_max_bid(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_draft_get_my_max_bid(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
