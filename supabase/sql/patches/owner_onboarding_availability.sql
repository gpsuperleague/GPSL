-- =============================================================================
-- Owner onboarding — match availability & timezone before club auction
-- Run after gpsl_waiting_list.sql, match_scheduling_phase1.sql, club_auction.sql
-- =============================================================================

ALTER TABLE public.gpsl_owner_registry
  ADD COLUMN IF NOT EXISTS owner_timezone text;

COMMENT ON COLUMN public.gpsl_owner_registry.owner_timezone IS
  'Display timezone set during club-auction onboarding; copied to Clubs.owner_timezone on assignment.';

CREATE TABLE IF NOT EXISTS public.gpsl_owner_registry_availability_slot (
  owner_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  iso_dow smallint NOT NULL CHECK (iso_dow >= 1 AND iso_dow <= 7),
  slot_minute smallint NOT NULL
    CHECK (slot_minute >= 0 AND slot_minute <= 1410 AND slot_minute % 30 = 0),
  PRIMARY KEY (owner_id, iso_dow, slot_minute)
);

CREATE INDEX IF NOT EXISTS gpsl_owner_registry_avail_owner_idx
  ON public.gpsl_owner_registry_availability_slot (owner_id);

ALTER TABLE public.gpsl_owner_registry_availability_slot ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_owner_registry_avail_self ON public.gpsl_owner_registry_availability_slot;
CREATE POLICY gpsl_owner_registry_avail_self ON public.gpsl_owner_registry_availability_slot
  FOR ALL TO authenticated
  USING (owner_id = auth.uid() OR public.is_gpsl_admin())
  WITH CHECK (owner_id = auth.uid() OR public.is_gpsl_admin());

-- ---------------------------------------------------------------------------
-- Readiness helper (tag + timezone + at least one weekly slot)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.owner_onboarding_auction_ready(p_owner_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    nullif(btrim(coalesce(r.owner_tag, '')), '') IS NOT NULL
    AND nullif(btrim(coalesce(r.owner_timezone, '')), '') IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM public.gpsl_owner_registry_availability_slot s
      WHERE s.owner_id = p_owner_id
    )
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = p_owner_id
    AND r.status = 'awaiting_club_auction';
$$;

-- ---------------------------------------------------------------------------
-- Copy registry onboarding availability onto the club after auction win
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.owner_onboarding_apply_availability_to_club(
  p_owner_id uuid,
  p_club_short_name text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(p_club_short_name));
  v_tz text;
  v_season_id bigint;
BEGIN
  IF p_owner_id IS NULL OR v_club IS NULL OR v_club = '' THEN
    RETURN;
  END IF;

  SELECT nullif(btrim(coalesce(r.owner_timezone, '')), '')
  INTO v_tz
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = p_owner_id;

  IF v_tz IS NOT NULL THEN
    UPDATE public."Clubs"
    SET owner_timezone = v_tz
    WHERE "ShortName" = v_club
      AND owner_id = p_owner_id;
  END IF;

  SELECT s.id INTO v_season_id
  FROM public.competition_seasons s
  WHERE s.is_current = true AND s.status = 'active'
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN;
  END IF;

  DELETE FROM public.club_owner_availability_slot
  WHERE season_id = v_season_id
    AND club_short_name = v_club;

  INSERT INTO public.club_owner_availability_slot (
    season_id, club_short_name, owner_id, iso_dow, slot_minute
  )
  SELECT
    v_season_id,
    v_club,
    p_owner_id,
    s.iso_dow,
    s.slot_minute
  FROM public.gpsl_owner_registry_availability_slot s
  WHERE s.owner_id = p_owner_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Owner RPCs — onboarding availability (no club yet)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.owner_onboarding_availability_context()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := auth.uid();
  v_tz text;
  v_slot_count int;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v_owner) THEN
    RAISE EXCEPTION 'Use club availability settings once you have a club';
  END IF;

  SELECT nullif(btrim(coalesce(r.owner_timezone, '')), ''), (
    SELECT count(*)::integer
    FROM public.gpsl_owner_registry_availability_slot s
    WHERE s.owner_id = v_owner
  )
  INTO v_tz, v_slot_count
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_owner;

  RETURN jsonb_build_object(
    'timezone', coalesce(v_tz, 'Europe/London'),
    'weekly_slots', (
      SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
          'iso_dow', s.iso_dow,
          'hour', s.slot_minute / 60,
          'minute', s.slot_minute % 60
        )
        ORDER BY s.iso_dow, s.slot_minute
      ), '[]'::jsonb)
      FROM public.gpsl_owner_registry_availability_slot s
      WHERE s.owner_id = v_owner
    ),
    'slot_count', coalesce(v_slot_count, 0),
    'holidays', '[]'::jsonb
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_onboarding_timezone_set(p_timezone text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := auth.uid();
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v_owner) THEN
    RAISE EXCEPTION 'Use club settings once you have a club';
  END IF;

  IF p_timezone IS NULL OR btrim(p_timezone) = '' THEN
    RAISE EXCEPTION 'Timezone is required';
  END IF;

  INSERT INTO public.gpsl_owner_registry (owner_id, status, owner_timezone, status_changed_at)
  VALUES (v_owner, 'awaiting_club_auction', btrim(p_timezone), now())
  ON CONFLICT (owner_id) DO UPDATE
  SET owner_timezone = excluded.owner_timezone,
      status = CASE
        WHEN gpsl_owner_registry.status = 'archived' THEN gpsl_owner_registry.status
        WHEN gpsl_owner_registry.status IS NULL THEN 'awaiting_club_auction'
        ELSE gpsl_owner_registry.status
      END,
      status_changed_at = now()
  WHERE gpsl_owner_registry.status <> 'archived';
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_onboarding_availability_save_weekly(p_slots jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_owner uuid := auth.uid();
  v_slot jsonb;
  v_isodow smallint;
  v_minute smallint;
BEGIN
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v_owner) THEN
    RAISE EXCEPTION 'Use club settings once you have a club';
  END IF;

  IF p_slots IS NULL OR jsonb_typeof(p_slots) <> 'array' THEN
    RAISE EXCEPTION 'Slots must be a JSON array';
  END IF;

  DELETE FROM public.gpsl_owner_registry_availability_slot
  WHERE owner_id = v_owner;

  FOR v_slot IN SELECT * FROM jsonb_array_elements(p_slots)
  LOOP
    v_isodow := (v_slot->>'iso_dow')::smallint;
    v_minute := (
      COALESCE((v_slot->>'hour')::integer, 0) * 60
      + COALESCE((v_slot->>'minute')::integer, 0)
    )::smallint;

    IF v_isodow IS NULL OR v_isodow < 1 OR v_isodow > 7 THEN
      RAISE EXCEPTION 'Invalid iso_dow in slot';
    END IF;

    IF v_minute % 30 <> 0 OR v_minute < 0 OR v_minute > 1410 THEN
      RAISE EXCEPTION 'Invalid time in slot (30-minute blocks only)';
    END IF;

    INSERT INTO public.gpsl_owner_registry_availability_slot (
      owner_id, iso_dow, slot_minute
    )
    VALUES (v_owner, v_isodow, v_minute);
  END LOOP;
END;
$function$;

-- ---------------------------------------------------------------------------
-- owner_registry_get_self — add onboarding availability fields
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.owner_registry_get_self()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.gpsl_owner_registry%rowtype;
  v_has_club boolean;
  v_tag text;
  v_pos int;
  v_total int;
  v_caretaker boolean;
  v_slot_count int;
  v_tz text;
  v_awaiting boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('authenticated', false);
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public."Clubs" c WHERE c.owner_id = auth.uid()
  ) INTO v_has_club;

  SELECT EXISTS (
    SELECT 1 FROM public.gpsl_club_caretaker ct
    WHERE ct.caretaker_owner_id = auth.uid() AND ct.ended_at IS NULL
  ) INTO v_caretaker;

  SELECT * INTO v_row
  FROM public.gpsl_owner_registry
  WHERE owner_id = auth.uid();

  v_tag := public.owner_registry_resolve_tag(auth.uid());
  v_tz := nullif(btrim(coalesce(v_row.owner_timezone, '')), '');

  SELECT count(*)::int INTO v_slot_count
  FROM public.gpsl_owner_registry_availability_slot s
  WHERE s.owner_id = auth.uid();

  SELECT w.list_position INTO v_pos
  FROM public.waiting_list_ordered_rows(false) w
  WHERE w.owner_id = auth.uid();

  SELECT count(*)::int INTO v_total
  FROM public.waiting_list_ordered_rows(false);

  v_awaiting := NOT v_has_club
    AND coalesce(v_row.status, '') = 'awaiting_club_auction';

  RETURN jsonb_build_object(
    'authenticated', true,
    'has_club', v_has_club,
    'status', v_row.status,
    'owner_tag', v_tag,
    'owner_timezone', v_tz,
    'availability_slot_count', coalesce(v_slot_count, 0),
    'pending_starting_balance', coalesce(v_row.pending_starting_balance, 0),
    'needs_club_auction', v_awaiting,
    'needs_owner_tag', v_awaiting AND v_tag IS NULL,
    'needs_onboarding_timezone', v_awaiting AND v_tz IS NULL,
    'needs_onboarding_availability', v_awaiting AND coalesce(v_slot_count, 0) < 1,
    'auction_onboarding_ready',
      v_awaiting
      AND v_tag IS NOT NULL
      AND v_tz IS NOT NULL
      AND coalesce(v_slot_count, 0) > 0,
    'is_member',
      NOT v_has_club
      AND public.waiting_list_on_list_status(coalesce(v_row.status, '')),
    'is_archived', coalesce(v_row.status, '') = 'archived',
    'is_caretaker', v_caretaker,
    'waiting_list_position', v_pos,
    'waiting_list_total', coalesce(v_total, 0)
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Club auction — require availability + timezone (mirrors owner tag gate)
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

  IF nullif(btrim(coalesce(v_registry.owner_timezone, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Set your timezone on awaiting_club.html before bidding';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.gpsl_owner_registry_availability_slot s
    WHERE s.owner_id = v_owner
  ) THEN
    RAISE EXCEPTION 'Set your match availability on awaiting_club.html before bidding';
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
-- Club auction settlement — copy onboarding availability to the club
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
  v_stadium numeric;
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

  v_stadium := coalesce(public.club_stadium_infra_purchase_cost(v_listing.club_short_name), 0);
  v_amount := greatest(v_amount, v_stadium);

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

  UPDATE public."Clubs"
  SET owner_id = v_winner,
      owner = coalesce(v_tag, owner)
  WHERE "ShortName" = v_listing.club_short_name;

  PERFORM public.owner_onboarding_apply_availability_to_club(
    v_winner,
    v_listing.club_short_name
  );

  PERFORM public.owner_apply_club_assignment_finances(
    v_listing.club_short_name,
    v_winner,
    v_starting,
    v_amount,
    'club_auction',
    jsonb_build_object(
      'listing_id', v_listing.id::text,
      'winning_bid', v_amount,
      'dup_key', v_listing.id::text
    ),
    format(
      'Club auction — %s (%s)',
      (SELECT c."Club" FROM public."Clubs" c WHERE c."ShortName" = v_listing.club_short_name),
      v_listing.club_short_name
    )
  );

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

  PERFORM public.owner_inbox_send_welcome(v_winner, v_listing.club_short_name);

  RAISE NOTICE 'Club auction listing % settled — % to owner % for % (stadium %)',
    p_listing_id, v_listing.club_short_name, v_winner, v_amount, v_stadium;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.owner_onboarding_availability_context() TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_onboarding_timezone_set(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_onboarding_availability_save_weekly(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_onboarding_auction_ready(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_registry_get_self() TO authenticated;

NOTIFY pgrst, 'reload schema';
