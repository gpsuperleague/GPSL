-- =============================================================================
-- Club auction — Phase 2 step 1 (SQL)
-- Vacant clubs listed for owners in awaiting_club_auction; highest bid wins.
-- Shares draft schedule: draft_auction_start_time + draft_random_finish_time.
-- Run after owner_onboarding_club_auction.sql (+ prestige views if using seed).
-- =============================================================================

ALTER TABLE public.global_settings
  ADD COLUMN IF NOT EXISTS club_auction_enabled boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.global_settings.club_auction_enabled IS
  'Season-start club auction for owners without a club (shares draft auction schedule).';

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public."Club_Auction_Listings" (
  id bigserial PRIMARY KEY,
  club_short_name text NOT NULL
    REFERENCES public."Clubs" ("ShortName") ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'Active'
    CHECK (status IN ('Active', 'Closed', 'Cancelled')),
  opening_bid numeric(14, 2) NOT NULL DEFAULT 0 CHECK (opening_bid >= 0),
  reserve_price numeric(14, 2) NOT NULL DEFAULT 0 CHECK (reserve_price >= 0),
  prestige_rank smallint,
  expected_position smallint,
  current_highest_bid numeric(14, 2),
  current_highest_bidder uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  winning_bid numeric(14, 2),
  winning_owner_id uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  transfer_completed boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS club_auction_listings_one_active_per_club_uidx
  ON public."Club_Auction_Listings" (club_short_name)
  WHERE status = 'Active';

CREATE TABLE IF NOT EXISTS public."Club_Auction_Bids" (
  id bigserial PRIMARY KEY,
  listing_id bigint NOT NULL
    REFERENCES public."Club_Auction_Listings" (id) ON DELETE CASCADE,
  club_short_name text NOT NULL
    REFERENCES public."Clubs" ("ShortName") ON DELETE CASCADE,
  bidder_owner_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  bid_amount numeric(14, 2) NOT NULL CHECK (bid_amount > 0),
  bid_time timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS club_auction_bids_listing_id_idx
  ON public."Club_Auction_Bids" (listing_id);

CREATE INDEX IF NOT EXISTS club_auction_bids_bidder_idx
  ON public."Club_Auction_Bids" (bidder_owner_id, bid_time DESC);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_auction_bid_increment()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT 500000::numeric;
$$;

CREATE OR REPLACE FUNCTION public.club_auction_opening_bid_for_rank(p_rank smallint)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT greatest(
    1000000::numeric,
    (61 - greatest(least(coalesce(p_rank, 60), 60), 1))::numeric * 1000000
  );
$$;

CREATE OR REPLACE FUNCTION public.club_auction_bidding_open_now()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    COALESCE(gs.club_auction_enabled, false)
    AND gs.draft_auction_start_time IS NOT NULL
    AND gs.draft_random_finish_time IS NOT NULL
    AND now() >= gs.draft_auction_start_time
    AND now() < gs.draft_random_finish_time
  FROM public.global_settings gs
  WHERE gs.id = 1;
$$;

CREATE OR REPLACE FUNCTION public.club_auction_owner_budget(p_owner_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(r.pending_starting_balance, 0)
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = p_owner_id;
$$;

CREATE OR REPLACE FUNCTION public.club_auction_min_next_bid(p_listing_id bigint)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Club_Auction_Listings"%rowtype;
BEGIN
  SELECT * INTO v_listing
  FROM public."Club_Auction_Listings"
  WHERE id = p_listing_id;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_listing.current_highest_bid IS NULL THEN
    RETURN v_listing.opening_bid;
  END IF;

  RETURN greatest(
    v_listing.opening_bid,
    v_listing.current_highest_bid + public.club_auction_bid_increment()
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_auction_get_state()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_gs public.global_settings%rowtype;
BEGIN
  SELECT * INTO v_gs FROM public.global_settings WHERE id = 1;

  RETURN jsonb_build_object(
    'enabled', coalesce(v_gs.club_auction_enabled, false),
    'bidding_open', public.club_auction_bidding_open_now(),
    'start_time', v_gs.draft_auction_start_time,
    'finish_time',
      CASE
        WHEN v_gs.draft_random_finish_time IS NOT NULL
         AND now() >= v_gs.draft_random_finish_time
        THEN v_gs.draft_random_finish_time
        ELSE NULL
      END,
    'bid_increment', public.club_auction_bid_increment(),
    'active_listings',
      (SELECT count(*)::int
       FROM public."Club_Auction_Listings" l
       WHERE l.status = 'Active')
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Public listing view (UI step 2)
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS public.club_auction_listings_public;

CREATE VIEW public.club_auction_listings_public
WITH (security_invoker = false)
AS
SELECT
  l.id,
  l.club_short_name,
  c."Club" AS club_name,
  c."Stadium" AS stadium,
  coalesce(c."Capacity", 0)::int AS capacity,
  c."Nation" AS nation,
  l.status,
  l.opening_bid,
  l.reserve_price,
  l.prestige_rank,
  l.expected_position,
  l.current_highest_bid,
  l.current_highest_bidder,
  r.owner_tag AS current_leader_tag,
  l.transfer_completed,
  l.created_at,
  l.updated_at,
  public.club_auction_min_next_bid(l.id) AS min_next_bid
FROM public."Club_Auction_Listings" l
JOIN public."Clubs" c ON c."ShortName" = l.club_short_name
LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = l.current_highest_bidder
WHERE l.status = 'Active'
  AND c.owner_id IS NULL
ORDER BY l.prestige_rank NULLS LAST, l.club_short_name;

GRANT SELECT ON public.club_auction_listings_public TO authenticated;
GRANT SELECT ON public.club_auction_listings_public TO anon;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

ALTER TABLE public."Club_Auction_Listings" ENABLE ROW LEVEL SECURITY;
ALTER TABLE public."Club_Auction_Bids" ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS club_auction_listings_select ON public."Club_Auction_Listings";
CREATE POLICY club_auction_listings_select ON public."Club_Auction_Listings"
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS club_auction_listings_admin ON public."Club_Auction_Listings";
CREATE POLICY club_auction_listings_admin ON public."Club_Auction_Listings"
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

DROP POLICY IF EXISTS club_auction_bids_select ON public."Club_Auction_Bids";
CREATE POLICY club_auction_bids_select ON public."Club_Auction_Bids"
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS club_auction_bids_admin ON public."Club_Auction_Bids";
CREATE POLICY club_auction_bids_admin ON public."Club_Auction_Bids"
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT ON public."Club_Auction_Listings" TO authenticated;
GRANT SELECT ON public."Club_Auction_Bids" TO authenticated;

-- ---------------------------------------------------------------------------
-- Place bid (owners awaiting club auction)
-- ---------------------------------------------------------------------------

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
  v_short text := upper(trim(p_club_short_name));
  v_amount numeric;
  v_listing public."Club_Auction_Listings"%rowtype;
  v_registry public.gpsl_owner_registry%rowtype;
  v_min numeric;
  v_budget numeric;
  v_other_club text;
  v_bid_id bigint;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF v_short IS NULL OR v_short = '' THEN
    RAISE EXCEPTION 'Club ShortName is required';
  END IF;

  IF NOT public.club_auction_bidding_open_now() THEN
    RAISE EXCEPTION 'Club auction bidding is not open';
  END IF;

  SELECT * INTO v_registry
  FROM public.gpsl_owner_registry
  WHERE owner_id = v_owner
  FOR UPDATE;

  IF NOT FOUND OR v_registry.status IS DISTINCT FROM 'awaiting_club_auction' THEN
    RAISE EXCEPTION 'You are not registered for the club auction';
  END IF;

  IF nullif(btrim(coalesce(v_registry.owner_tag, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Set your owner tag on awaiting_club.html before bidding';
  END IF;

  IF EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v_owner) THEN
    RAISE EXCEPTION 'You already have a club';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE c."ShortName" = v_short
      AND c.owner_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Club % is no longer available', v_short;
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
    AND l.current_highest_bidder = v_owner
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

  v_min := public.club_auction_min_next_bid(v_listing.id);
  IF v_amount < v_min THEN
    RAISE EXCEPTION 'Minimum bid is ₿%', to_char(v_min, 'FM999,999,999,999');
  END IF;

  IF v_listing.current_highest_bidder = v_owner
     AND v_amount <= coalesce(v_listing.current_highest_bid, 0) THEN
    RAISE EXCEPTION 'Raise your bid above ₿%',
      to_char(coalesce(v_listing.current_highest_bid, 0), 'FM999,999,999,999');
  END IF;

  INSERT INTO public."Club_Auction_Bids" (
    listing_id,
    club_short_name,
    bidder_owner_id,
    bid_amount,
    bid_time
  )
  VALUES (
    v_listing.id,
    v_short,
    v_owner,
    v_amount,
    now()
  )
  RETURNING id INTO v_bid_id;

  UPDATE public."Club_Auction_Listings"
  SET current_highest_bid = v_amount,
      current_highest_bidder = v_owner,
      updated_at = now()
  WHERE id = v_listing.id;

  RETURN jsonb_build_object(
    'ok', true,
    'bid_id', v_bid_id,
    'listing_id', v_listing.id,
    'club_short_name', v_short,
    'bid_amount', v_amount,
    'min_next_bid', v_amount + public.club_auction_bid_increment(),
    'remaining_budget', v_budget - v_amount
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Settlement
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.transferengine_accept_club_auction_sale(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Club_Auction_Listings"%rowtype;
  v_amount numeric;
  v_winner uuid;
  v_registry public.gpsl_owner_registry%rowtype;
  v_tag text;
  v_starting numeric;
  v_club_name text;
BEGIN
  SELECT * INTO v_listing
  FROM public."Club_Auction_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Club auction listing % not found', p_listing_id;
    RETURN;
  END IF;

  IF v_listing.status <> 'Active' THEN
    RAISE NOTICE 'Club auction listing % already processed', p_listing_id;
    RETURN;
  END IF;

  SELECT b.bid_amount, b.bidder_owner_id
  INTO v_amount, v_winner
  FROM public."Club_Auction_Bids" b
  WHERE b.listing_id = v_listing.id
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  IF v_winner IS NULL OR v_amount IS NULL THEN
    v_winner := v_listing.current_highest_bidder;
    v_amount := v_listing.current_highest_bid;
  END IF;

  IF v_winner IS NULL OR v_amount IS NULL THEN
    UPDATE public."Club_Auction_Listings"
    SET status = 'Closed',
        transfer_completed = false,
        updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  IF v_amount < v_listing.reserve_price THEN
    UPDATE public."Club_Auction_Listings"
    SET status = 'Closed',
        transfer_completed = false,
        updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE c."ShortName" = v_listing.club_short_name
      AND c.owner_id IS NOT NULL
  ) THEN
    RAISE NOTICE 'Club % already has an owner — cannot settle listing %',
      v_listing.club_short_name, p_listing_id;
    UPDATE public."Club_Auction_Listings"
    SET status = 'Closed',
        transfer_completed = false,
        updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  SELECT * INTO v_registry
  FROM public.gpsl_owner_registry
  WHERE owner_id = v_winner
  FOR UPDATE;

  IF NOT FOUND
     OR v_registry.status IS DISTINCT FROM 'awaiting_club_auction'
     OR EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v_winner) THEN
    RAISE NOTICE 'Winner % cannot take club for listing %', v_winner, p_listing_id;
    UPDATE public."Club_Auction_Listings"
    SET status = 'Closed',
        transfer_completed = false,
        updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  IF v_amount > coalesce(v_registry.pending_starting_balance, 0) THEN
    RAISE NOTICE 'Winning bid % exceeds budget for listing %', v_amount, p_listing_id;
    UPDATE public."Club_Auction_Listings"
    SET status = 'Closed',
        transfer_completed = false,
        updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  v_tag := nullif(btrim(coalesce(v_registry.owner_tag, '')), '');
  v_starting := greatest(coalesce(v_registry.pending_starting_balance, 0), 0);

  SELECT c."Club" INTO v_club_name
  FROM public."Clubs" c
  WHERE c."ShortName" = v_listing.club_short_name;

  UPDATE public."Clubs"
  SET owner_id = v_winner,
      owner = coalesce(v_tag, owner)
  WHERE "ShortName" = v_listing.club_short_name;

  IF EXISTS (
    SELECT 1 FROM public."Club_Finances" f
    WHERE f.club_name = v_listing.club_short_name
  ) THEN
    UPDATE public."Club_Finances"
    SET balance = v_starting
    WHERE club_name = v_listing.club_short_name;
  ELSE
    INSERT INTO public."Club_Finances" (club_name, balance)
    VALUES (v_listing.club_short_name, v_starting);
  END IF;

  IF v_amount > 0 THEN
    PERFORM public.post_club_ledger(
      v_listing.club_short_name,
      'infra_purchase',
      -v_amount,
      format(
        'Club auction — %s (%s)',
        coalesce(v_club_name, v_listing.club_short_name),
        v_listing.club_short_name
      ),
      jsonb_build_object(
        'source', 'club_auction',
        'listing_id', v_listing.id,
        'winning_owner_id', v_winner,
        'winning_bid', v_amount,
        'starting_budget', v_starting
      )
    );
  END IF;

  UPDATE public.gpsl_owner_registry
  SET status = 'active',
      owner_tag = coalesce(v_tag, owner_tag),
      last_club_short_name = v_listing.club_short_name,
      pending_starting_balance = 0,
      status_changed_at = now()
  WHERE owner_id = v_winner;

  UPDATE public."Club_Auction_Listings"
  SET status = 'Closed',
      transfer_completed = true,
      winning_bid = v_amount,
      winning_owner_id = v_winner,
      current_highest_bid = v_amount,
      current_highest_bidder = v_winner,
      updated_at = now()
  WHERE id = v_listing.id;

  RAISE NOTICE 'Club auction listing % settled — % to owner % for %',
    p_listing_id, v_listing.club_short_name, v_winner, v_amount;
END;
$function$;

CREATE OR REPLACE FUNCTION public.transferengine_settle_club_auctions_only()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_enabled boolean;
  v_finish timestamptz;
  v_listing public."Club_Auction_Listings"%rowtype;
BEGIN
  SELECT club_auction_enabled, draft_random_finish_time
  INTO v_enabled, v_finish
  FROM public.global_settings
  WHERE id = 1;

  IF NOT COALESCE(v_enabled, false) THEN
    RETURN;
  END IF;

  IF v_finish IS NULL OR now() < v_finish THEN
    RETURN;
  END IF;

  FOR v_listing IN
    SELECT *
    FROM public."Club_Auction_Listings"
    WHERE status = 'Active'
    ORDER BY id
  LOOP
    PERFORM public.transferengine_accept_club_auction_sale(v_listing.id);
  END LOOP;
END;
$function$;

-- Hook into existing draft settlement cron (after manager draft)
CREATE OR REPLACE FUNCTION public.transferengine_settle_draft_auctions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_settings record;
  v_listing  public."Player_Transfer_Listings"%rowtype;
  v_now      timestamptz := now();
BEGIN
  SELECT
    draft_auction_enabled,
    manager_draft_auction_enabled,
    club_auction_enabled,
    draft_random_finish_time
  INTO v_settings
  FROM public.global_settings
  WHERE id = 1;

  IF NOT COALESCE(v_settings.draft_auction_enabled, false)
     AND NOT COALESCE(v_settings.manager_draft_auction_enabled, false)
     AND NOT COALESCE(v_settings.club_auction_enabled, false) THEN
    RETURN;
  END IF;

  IF v_settings.draft_random_finish_time IS NULL THEN
    RETURN;
  END IF;

  IF v_now < v_settings.draft_random_finish_time THEN
    RETURN;
  END IF;

  PERFORM public.transferengine_process_standard_listings(v_now);

  IF COALESCE(v_settings.draft_auction_enabled, false)
     AND NOT public.transferengine_standard_listings_block_draft_settlement(
       v_now,
       v_settings.draft_random_finish_time
     ) THEN
    FOR v_listing IN
      SELECT *
      FROM public."Player_Transfer_Listings"
      WHERE listing_type = 'draft' AND status = 'Active'
    LOOP
      PERFORM public.transferengine_accept_draft_sale(v_listing.id);
    END LOOP;
  END IF;

  PERFORM public.transferengine_settle_manager_draft_auctions_only();
  PERFORM public.transferengine_settle_club_auctions_only();
END;
$function$;

-- ---------------------------------------------------------------------------
-- Admin
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_set_club_auction_enabled(p_enabled boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  UPDATE public.global_settings
  SET club_auction_enabled = coalesce(p_enabled, false),
      updated_at = now()
  WHERE id = 1;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_club_auction_seed_listings()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_opening numeric;
  v_inserted int := 0;
  v_skipped int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  FOR v_club IN
    SELECT
      c."ShortName" AS club_short_name,
      p.prestige_rank
    FROM public."Clubs" c
    LEFT JOIN public.competition_club_prestige_public p
      ON p.club_short_name = c."ShortName"
    WHERE c."ShortName" <> 'FOREIGN'
      AND c.owner_id IS NULL
    ORDER BY p.prestige_rank NULLS LAST, c."ShortName"
  LOOP
    IF EXISTS (
      SELECT 1
      FROM public."Club_Auction_Listings" l
      WHERE l.club_short_name = v_club.club_short_name
        AND l.status = 'Active'
    ) THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    v_opening := public.club_auction_opening_bid_for_rank(v_club.prestige_rank);

    INSERT INTO public."Club_Auction_Listings" (
      club_short_name,
      status,
      opening_bid,
      reserve_price,
      prestige_rank,
      expected_position,
      created_at,
      updated_at
    )
    VALUES (
      v_club.club_short_name,
      'Active',
      v_opening,
      v_opening,
      v_club.prestige_rank,
      v_club.prestige_rank,
      now(),
      now()
    );

    v_inserted := v_inserted + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'inserted', v_inserted,
    'skipped_existing_active', v_skipped
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_club_auction_reset()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listings int;
  v_bids int;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT count(*)::int INTO v_bids FROM public."Club_Auction_Bids";
  SELECT count(*)::int INTO v_listings FROM public."Club_Auction_Listings";

  DELETE FROM public."Club_Auction_Bids" WHERE true;
  DELETE FROM public."Club_Auction_Listings" WHERE true;

  RETURN jsonb_build_object(
    'ok', true,
    'deleted_listings', v_listings,
    'deleted_bids', v_bids
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_settle_club_auctions_now()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_before int;
  v_after int;
  v_finish timestamptz;
  v_listing public."Club_Auction_Listings"%rowtype;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT draft_random_finish_time INTO v_finish
  FROM public.global_settings
  WHERE id = 1;

  SELECT count(*)::int INTO v_before
  FROM public."Club_Auction_Listings"
  WHERE status = 'Active';

  -- Admin override: settle now regardless of secret finish time
  FOR v_listing IN
    SELECT *
    FROM public."Club_Auction_Listings"
    WHERE status = 'Active'
    ORDER BY id
  LOOP
    PERFORM public.transferengine_accept_club_auction_sale(v_listing.id);
  END LOOP;

  SELECT count(*)::int INTO v_after
  FROM public."Club_Auction_Listings"
  WHERE status = 'Active';

  RETURN jsonb_build_object(
    'ok', true,
    'active_before', v_before,
    'active_after', v_after,
    'settled_count', v_before - v_after,
    'secret_finish_passed', v_finish IS NOT NULL AND now() >= v_finish,
    'still_active', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'listing_id', l.id,
        'club_short_name', l.club_short_name,
        'high_bid', l.current_highest_bid,
        'high_bidder', l.current_highest_bidder,
        'leader_tag', r.owner_tag
      ) ORDER BY l.prestige_rank NULLS LAST, l.club_short_name), '[]'::jsonb)
      FROM public."Club_Auction_Listings" l
      LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = l.current_highest_bidder
      WHERE l.status = 'Active'
    )
  );
END;
$function$;

-- Optional: merge club_auction_bidding_open into global_settings_public via
-- repair_global_settings_public.sql after applying this patch.
-- UI can use club_auction_get_state() until then.

GRANT EXECUTE ON FUNCTION public.club_auction_get_state() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_place_bid(text, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_owner_budget(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_min_next_bid(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_accept_club_auction_sale(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_club_auction_enabled(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_club_auction_seed_listings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_club_auction_reset() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_settle_club_auctions_now() TO authenticated;

NOTIFY pgrst, 'reload schema';
