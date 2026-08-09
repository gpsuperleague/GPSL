-- =============================================================================
-- Club auction settle harden + SOA (ex-NMU) repair
-- =============================================================================
-- Symptom: random finish assigned every club except SOA (rebranded from NMU).
-- Settlement failures are swallowed per-listing (WARNING only), so one club can
-- stay Active / Closed-incomplete while others complete.
--
-- Rename-related failure modes this patch addresses:
--   1) Orphan non-FK keys still on NMU (club_auction_max_bids, Club_Finances)
--   2) Listing/club ShortName mismatch after partial swap (alias NMU ↔ SOA)
--   3) Non-idempotent settle: club already owned by winner, or registry active
--      with no club, blocked a retry
--   4) Welcome inbox aborting after assignment (now non-fatal)
--   5) UPDATE Clubs matching 0 rows still continuing (now raises)
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- Bottom section repairs SOA automatically.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Resolve ShortName (trim/upper + NMU→SOA alias when NMU row is gone)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_auction_resolve_short_name(p_club_short_name text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_in text := upper(btrim(coalesce(p_club_short_name, '')));
  v_out text;
BEGIN
  IF v_in = '' THEN
    RETURN NULL;
  END IF;

  IF EXISTS (SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_in) THEN
    RETURN v_in;
  END IF;

  -- Franchise swap leftovers: listing/bid still says NMU, club is SOA
  IF v_in = 'NMU'
     AND EXISTS (SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = 'SOA') THEN
    RETURN 'SOA';
  END IF;

  -- Inverse (should be rare): asked for SOA, only NMU remains
  IF v_in = 'SOA'
     AND EXISTS (SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = 'NMU')
     AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = 'SOA') THEN
    RETURN 'NMU';
  END IF;

  SELECT c."ShortName" INTO v_out
  FROM public."Clubs" c
  WHERE upper(btrim(c."ShortName")) = v_in
  LIMIT 1;

  RETURN v_out;
END;
$function$;

COMMENT ON FUNCTION public.club_auction_resolve_short_name(text) IS
  'Normalise club auction ShortName; maps NMU→SOA when the franchise was swapped.';

-- ---------------------------------------------------------------------------
-- Migrate orphan non-FK rows after a ShortName rename
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_auction_migrate_short_name_orphans(
  p_from text,
  p_to text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_from text := upper(btrim(coalesce(p_from, '')));
  v_to text := upper(btrim(coalesce(p_to, '')));
  v_max_bids int := 0;
  v_finances int := 0;
  v_listings int := 0;
  v_bids int := 0;
BEGIN
  IF v_from = '' OR v_to = '' OR v_from = v_to THEN
    RETURN jsonb_build_object('ok', false, 'error', 'from/to required and must differ');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c."ShortName" = v_to) THEN
    RETURN jsonb_build_object('ok', false, 'error', format('target club %s missing', v_to));
  END IF;

  -- Max bids: no FK to Clubs — swap scripts historically missed this table
  IF to_regclass('public.club_auction_max_bids') IS NOT NULL THEN
    UPDATE public.club_auction_max_bids m
    SET club_short_name = v_to,
        updated_at = now()
    WHERE m.club_short_name = v_from
      AND NOT EXISTS (
        SELECT 1
        FROM public.club_auction_max_bids x
        WHERE x.owner_id = m.owner_id
          AND x.club_short_name = v_to
      );
    GET DIAGNOSTICS v_max_bids = ROW_COUNT;

    DELETE FROM public.club_auction_max_bids
    WHERE club_short_name = v_from;
  END IF;

  -- Club_Finances: may lack FK on some installs; merge NMU → SOA
  IF EXISTS (
    SELECT 1 FROM public."Club_Finances" f WHERE f.club_name = v_from
  ) THEN
    IF EXISTS (
      SELECT 1 FROM public."Club_Finances" f WHERE f.club_name = v_to
    ) THEN
      DELETE FROM public."Club_Finances" WHERE club_name = v_from;
      v_finances := 1;
    ELSE
      UPDATE public."Club_Finances"
      SET club_name = v_to
      WHERE club_name = v_from;
      GET DIAGNOSTICS v_finances = ROW_COUNT;
    END IF;
  END IF;

  -- Listings / bids (normally FK-updated by swap; repair if orphaned)
  BEGIN
    UPDATE public."Club_Auction_Listings"
    SET club_short_name = v_to,
        updated_at = now()
    WHERE club_short_name = v_from;
    GET DIAGNOSTICS v_listings = ROW_COUNT;
  EXCEPTION WHEN foreign_key_violation THEN
    v_listings := 0;
  END;

  BEGIN
    UPDATE public."Club_Auction_Bids"
    SET club_short_name = v_to
    WHERE club_short_name = v_from;
    GET DIAGNOSTICS v_bids = ROW_COUNT;
  EXCEPTION WHEN foreign_key_violation THEN
    v_bids := 0;
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'from', v_from,
    'to', v_to,
    'max_bids_moved', v_max_bids,
    'finances_moved', v_finances,
    'listings_moved', v_listings,
    'bids_moved', v_bids
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_auction_resolve_short_name(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_auction_migrate_short_name_orphans(text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Hardened club auction settlement
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
  v_club text;
  v_club_name text;
  v_rows int;
  v_raw_bid numeric;
  v_winner_owns_this boolean := false;
  v_winner_owns_other boolean := false;
  v_status_ok boolean := false;
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
    RAISE NOTICE 'Club auction listing % already processed (status=%)',
      p_listing_id, v_listing.status;
    RETURN;
  END IF;

  v_club := public.club_auction_resolve_short_name(v_listing.club_short_name);
  IF v_club IS NULL THEN
    RAISE WARNING
      'Club auction listing % — club % not found (rename/orphan?). Leaving Active.',
      p_listing_id, v_listing.club_short_name;
    RETURN;
  END IF;

  -- Repoint listing/bids if alias resolved (e.g. NMU → SOA)
  IF v_club IS DISTINCT FROM v_listing.club_short_name THEN
    PERFORM public.club_auction_migrate_short_name_orphans(
      v_listing.club_short_name,
      v_club
    );
    UPDATE public."Club_Auction_Listings"
    SET club_short_name = v_club,
        updated_at = now()
    WHERE id = v_listing.id;
    v_listing.club_short_name := v_club;
  ELSE
    -- Still migrate orphan max_bids / finances from known prior code
    IF v_club = 'SOA' THEN
      PERFORM public.club_auction_migrate_short_name_orphans('NMU', 'SOA');
    END IF;
  END IF;

  SELECT c."Club" INTO v_club_name
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

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

  v_raw_bid := v_amount;

  IF v_raw_bid < v_listing.reserve_price THEN
    UPDATE public."Club_Auction_Listings"
    SET status = 'Closed',
        transfer_completed = false,
        updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  v_winner_owns_this := EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE c."ShortName" = v_club
      AND c.owner_id = v_winner
  );
  v_winner_owns_other := EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE c.owner_id = v_winner
      AND c."ShortName" IS DISTINCT FROM v_club
  );

  -- Idempotent: winner already on this club — finish listing/registry
  IF v_winner_owns_this THEN
    SELECT * INTO v_registry
    FROM public.gpsl_owner_registry
    WHERE owner_id = v_winner;

    v_tag := nullif(btrim(coalesce(v_registry.owner_tag, '')), '');
    v_starting := greatest(coalesce(v_registry.pending_starting_balance, 0), 0);
    v_stadium := coalesce(public.club_stadium_infra_purchase_cost(v_club), 0);
    v_amount := greatest(v_amount, v_stadium);

    BEGIN
      PERFORM public.owner_apply_club_assignment_finances(
        v_club,
        v_winner,
        greatest(v_starting, v_amount),
        v_amount,
        'club_auction',
        jsonb_build_object(
          'listing_id', v_listing.id::text,
          'winning_bid', v_amount,
          'dup_key', v_listing.id::text
        ),
        format('Club auction — %s (%s)', coalesce(v_club_name, v_club), v_club)
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Club auction listing % finance (idempotent) failed: %',
        p_listing_id, SQLERRM;
    END;

    UPDATE public.gpsl_owner_registry
    SET status = 'active',
        owner_tag = coalesce(v_tag, owner_tag),
        last_club_short_name = v_club,
        pending_starting_balance = 0,
        status_changed_at = now()
    WHERE owner_id = v_winner;

    UPDATE public."Club_Auction_Listings"
    SET status = 'Closed',
        transfer_completed = true,
        winning_bid = v_amount,
        winning_owner_id = v_winner,
        current_highest_bid = coalesce(current_highest_bid, v_amount),
        current_highest_bidder = coalesce(current_highest_bidder, v_winner),
        club_short_name = v_club,
        updated_at = now()
    WHERE id = v_listing.id;

    BEGIN
      PERFORM public.owner_inbox_send_welcome(v_winner, v_club);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Club auction listing % welcome failed: %', p_listing_id, SQLERRM;
    END;

    RAISE NOTICE 'Club auction listing % already owned by winner — marked complete (%)',
      p_listing_id, v_club;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE c."ShortName" = v_club
      AND c.owner_id IS NOT NULL
  ) THEN
    RAISE NOTICE 'Club % already has an owner — cannot settle listing %',
      v_club, p_listing_id;
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

  -- Allow awaiting_club_auction, or active-with-no-club (partial prior settle)
  v_status_ok := FOUND
    AND NOT v_winner_owns_other
    AND (
      v_registry.status = 'awaiting_club_auction'
      OR (
        v_registry.status = 'active'
        AND NOT EXISTS (SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v_winner)
      )
    );

  IF NOT v_status_ok THEN
    RAISE NOTICE
      'Winner % cannot take club for listing % (status=%, owns_other=%)',
      v_winner, p_listing_id, v_registry.status, v_winner_owns_other;
    UPDATE public."Club_Auction_Listings"
    SET status = 'Closed',
        transfer_completed = false,
        updated_at = now()
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  v_stadium := coalesce(public.club_stadium_infra_purchase_cost(v_club), 0);
  v_amount := greatest(v_raw_bid, v_stadium);

  -- After a rebrand, stadium cost can jump above the bid. Prefer charging the
  -- raw winning bid when that still fits the budget and meets reserve.
  IF v_amount > coalesce(v_registry.pending_starting_balance, 0)
     AND v_raw_bid <= coalesce(v_registry.pending_starting_balance, 0)
     AND v_raw_bid >= v_listing.reserve_price THEN
    RAISE NOTICE
      'Club auction listing % — stadium floor % > budget; settling at bid %',
      p_listing_id, v_stadium, v_raw_bid;
    v_amount := v_raw_bid;
  END IF;

  IF v_amount > coalesce(v_registry.pending_starting_balance, 0) THEN
    RAISE NOTICE 'Winning bid % exceeds budget % for listing %',
      v_amount, v_registry.pending_starting_balance, p_listing_id;
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
  WHERE "ShortName" = v_club;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN
    RAISE EXCEPTION
      'Club auction listing % — Clubs update matched % rows for % (expected 1)',
      p_listing_id, v_rows, v_club;
  END IF;

  PERFORM public.owner_apply_club_assignment_finances(
    v_club,
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
      coalesce(v_club_name, v_club),
      v_club
    )
  );

  UPDATE public.gpsl_owner_registry
  SET status = 'active',
      owner_tag = coalesce(v_tag, owner_tag),
      last_club_short_name = v_club,
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
      club_short_name = v_club,
      updated_at = now()
  WHERE id = v_listing.id;

  BEGIN
    PERFORM public.owner_inbox_send_welcome(v_winner, v_club);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Club auction listing % welcome failed: %', p_listing_id, SQLERRM;
  END;

  RAISE NOTICE 'Club auction listing % settled — % to owner % for % (stadium %)',
    p_listing_id, v_club, v_winner, v_amount, v_stadium;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transferengine_accept_club_auction_sale(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- Find winner for a club auction listing (bids → listing high → max_bids)
-- Searches SOA + NMU so rename orphans still resolve.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_auction_find_winner(
  p_listing_id bigint,
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Club_Auction_Listings"%rowtype;
  v_club text := upper(btrim(coalesce(p_club_short_name, '')));
  v_winner uuid;
  v_amount numeric;
  v_source text;
  v_aliases text[];
BEGIN
  IF p_listing_id IS NOT NULL THEN
    SELECT * INTO v_listing
    FROM public."Club_Auction_Listings"
    WHERE id = p_listing_id;
  END IF;

  IF v_club = '' AND FOUND THEN
    v_club := upper(btrim(v_listing.club_short_name));
  END IF;

  IF v_club IN ('SOA', 'NMU') THEN
    v_aliases := ARRAY['SOA', 'NMU'];
  ELSIF v_club <> '' THEN
    v_aliases := ARRAY[v_club];
  ELSE
    v_aliases := ARRAY[]::text[];
  END IF;

  -- 1) Bids on this listing
  IF p_listing_id IS NOT NULL THEN
    SELECT b.bidder_owner_id, b.bid_amount
    INTO v_winner, v_amount
    FROM public."Club_Auction_Bids" b
    WHERE b.listing_id = p_listing_id
    ORDER BY b.bid_amount DESC, b.bid_time ASC
    LIMIT 1;
    IF v_winner IS NOT NULL THEN
      v_source := 'bids_on_listing';
    END IF;
  END IF;

  -- 2) Listing high-bid columns
  IF v_winner IS NULL AND v_listing.current_highest_bidder IS NOT NULL THEN
    v_winner := v_listing.current_highest_bidder;
    v_amount := v_listing.current_highest_bid;
    v_source := 'listing_current_highest';
  END IF;

  -- 3) Any bid row keyed to SOA/NMU (wrong listing_id after re-seed)
  IF v_winner IS NULL AND cardinality(v_aliases) > 0 THEN
    SELECT b.bidder_owner_id, b.bid_amount
    INTO v_winner, v_amount
    FROM public."Club_Auction_Bids" b
    WHERE b.club_short_name = ANY (v_aliases)
    ORDER BY b.bid_amount DESC, b.bid_time ASC
    LIMIT 1;
    IF v_winner IS NOT NULL THEN
      v_source := 'bids_by_club_short_name';
    END IF;
  END IF;

  -- 4) Proxy max bids (no FK — often left on NMU after swap)
  IF v_winner IS NULL
     AND cardinality(v_aliases) > 0
     AND to_regclass('public.club_auction_max_bids') IS NOT NULL THEN
    SELECT m.owner_id, m.max_amount
    INTO v_winner, v_amount
    FROM public.club_auction_max_bids m
    JOIN public.gpsl_owner_registry r ON r.owner_id = m.owner_id
    WHERE m.club_short_name = ANY (v_aliases)
      AND r.status IS DISTINCT FROM 'archived'
      AND NOT EXISTS (
        SELECT 1 FROM public."Clubs" c WHERE c.owner_id = m.owner_id
      )
    ORDER BY m.max_amount DESC, m.updated_at ASC
    LIMIT 1;

    IF v_winner IS NOT NULL THEN
      v_source := 'max_bids';
      -- Settle at listing opening/reserve (max is only a ceiling)
      IF v_listing.id IS NOT NULL THEN
        v_amount := greatest(
          coalesce(v_listing.opening_bid, 0),
          coalesce(v_listing.reserve_price, 0),
          coalesce(v_listing.current_highest_bid, 0)
        );
        IF v_amount <= 0 THEN
          SELECT m.max_amount INTO v_amount
          FROM public.club_auction_max_bids m
          WHERE m.owner_id = v_winner
            AND m.club_short_name = ANY (v_aliases)
          ORDER BY m.max_amount DESC
          LIMIT 1;
        END IF;
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'winner_owner_id', v_winner,
    'amount', v_amount,
    'source', v_source,
    'club', nullif(v_club, ''),
    'listing_id', p_listing_id
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Admin repair: diagnose + settle one club (SOA by default)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_repair_club_auction_club(
  p_club_short_name text DEFAULT 'SOA'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_in text := upper(btrim(coalesce(p_club_short_name, 'SOA')));
  v_club text;
  v_listing public."Club_Auction_Listings"%rowtype;
  v_migrate jsonb;
  v_winner uuid;
  v_amount numeric;
  v_owner uuid;
  v_diag jsonb;
  v_found jsonb;
  v_err text;
  v_bid_count int := 0;
  v_max_count int := 0;
  v_opening numeric;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_in IN ('SOA', 'NMU') THEN
    v_migrate := public.club_auction_migrate_short_name_orphans('NMU', 'SOA');
  ELSE
    v_migrate := jsonb_build_object('ok', true, 'skipped', true);
  END IF;

  v_club := public.club_auction_resolve_short_name(v_in);
  IF v_club IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', format('Club %s not found', v_in),
      'migrate', v_migrate
    );
  END IF;

  -- Prefer listing that still has a high bidder / bid rows / incomplete transfer
  SELECT l.* INTO v_listing
  FROM public."Club_Auction_Listings" l
  WHERE (
      (v_club IN ('SOA', 'NMU') AND l.club_short_name IN ('SOA', 'NMU'))
      OR (v_club NOT IN ('SOA', 'NMU') AND l.club_short_name = v_club)
    )
  ORDER BY
    CASE WHEN l.club_short_name = v_club THEN 0 ELSE 1 END,
    CASE WHEN coalesce(l.transfer_completed, false) THEN 2
         WHEN l.status = 'Active' THEN 0
         ELSE 1 END,
    CASE WHEN l.current_highest_bidder IS NOT NULL THEN 0 ELSE 1 END,
    (
      SELECT count(*)::int FROM public."Club_Auction_Bids" b WHERE b.listing_id = l.id
    ) DESC,
    l.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', format('No club auction listing for %s', v_club),
      'migrate', v_migrate
    );
  END IF;

  -- Ensure listing points at live ShortName
  IF v_listing.club_short_name IS DISTINCT FROM v_club THEN
    UPDATE public."Club_Auction_Listings"
    SET club_short_name = v_club, updated_at = now()
    WHERE id = v_listing.id;
    v_listing.club_short_name := v_club;
  END IF;

  SELECT c.owner_id INTO v_owner
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  SELECT count(*)::int INTO v_bid_count
  FROM public."Club_Auction_Bids" b
  WHERE b.listing_id = v_listing.id
     OR b.club_short_name IN (v_club, 'SOA', 'NMU');

  IF to_regclass('public.club_auction_max_bids') IS NOT NULL THEN
    SELECT count(*)::int INTO v_max_count
    FROM public.club_auction_max_bids m
    WHERE m.club_short_name IN (v_club, 'SOA', 'NMU');
  END IF;

  v_found := public.club_auction_find_winner(v_listing.id, v_club);
  v_winner := nullif(v_found->>'winner_owner_id', '')::uuid;
  v_amount := nullif(v_found->>'amount', '')::numeric;

  v_diag := jsonb_build_object(
    'club', v_club,
    'listing_id', v_listing.id,
    'listing_status', v_listing.status,
    'transfer_completed', v_listing.transfer_completed,
    'opening_bid', v_listing.opening_bid,
    'reserve_price', v_listing.reserve_price,
    'current_highest_bid', v_listing.current_highest_bid,
    'current_highest_bidder', v_listing.current_highest_bidder,
    'club_owner_id', v_owner,
    'winner_owner_id', v_winner,
    'winning_bid', v_amount,
    'winner_source', v_found->>'source',
    'bid_rows_seen', v_bid_count,
    'max_bid_rows_seen', v_max_count,
    'migrate', v_migrate
  );

  -- Already complete
  IF v_listing.transfer_completed
     AND v_owner IS NOT NULL
     AND (v_winner IS NULL OR v_owner = v_winner) THEN
    RETURN v_diag || jsonb_build_object('ok', true, 'action', 'already_complete');
  END IF;

  -- Owner already correct; just close listing
  IF v_owner IS NOT NULL AND v_winner IS NOT NULL AND v_owner = v_winner THEN
    UPDATE public."Club_Auction_Listings"
    SET status = 'Closed',
        transfer_completed = true,
        winning_bid = coalesce(v_amount, winning_bid),
        winning_owner_id = v_winner,
        current_highest_bid = coalesce(current_highest_bid, v_amount),
        current_highest_bidder = coalesce(current_highest_bidder, v_winner),
        updated_at = now()
    WHERE id = v_listing.id;

    UPDATE public.gpsl_owner_registry
    SET status = 'active',
        last_club_short_name = v_club,
        pending_starting_balance = 0,
        status_changed_at = now()
    WHERE owner_id = v_winner;

    BEGIN
      PERFORM public.owner_inbox_send_welcome(v_winner, v_club);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    RETURN v_diag || jsonb_build_object('ok', true, 'action', 'closed_listing_for_existing_owner');
  END IF;

  IF v_owner IS NOT NULL AND v_winner IS NOT NULL AND v_owner IS DISTINCT FROM v_winner THEN
    RETURN v_diag || jsonb_build_object(
      'ok', false,
      'error', 'club_has_different_owner',
      'hint', 'Clear Clubs.owner_id for this club in SQL if that owner is wrong, then re-run repair.'
    );
  END IF;

  IF v_winner IS NULL THEN
    RETURN v_diag || jsonb_build_object(
      'ok', false,
      'error', 'no_winner_to_settle',
      'hint', 'No Club_Auction_Bids / current_highest / max_bids for SOA|NMU. Paste the diagnose queries below, or force-assign with admin_force_club_auction_assign(email).'
    );
  END IF;

  -- Restore high-bid on listing so accept_sale can see a winner
  v_opening := coalesce(v_listing.opening_bid, v_listing.reserve_price, v_amount, 0);
  v_amount := greatest(coalesce(v_amount, 0), v_opening);

  UPDATE public."Club_Auction_Listings"
  SET status = 'Active',
      transfer_completed = false,
      club_short_name = v_club,
      current_highest_bid = v_amount,
      current_highest_bidder = v_winner,
      reserve_price = least(coalesce(reserve_price, v_amount), v_amount),
      updated_at = now()
  WHERE id = v_listing.id;

  -- Ensure a bid row exists (accept prefers Bids table)
  IF NOT EXISTS (
    SELECT 1 FROM public."Club_Auction_Bids" b
    WHERE b.listing_id = v_listing.id
      AND b.bidder_owner_id = v_winner
      AND b.bid_amount = v_amount
  ) THEN
    INSERT INTO public."Club_Auction_Bids" (
      listing_id, club_short_name, bidder_owner_id, bid_amount, bid_time
    ) VALUES (
      v_listing.id, v_club, v_winner, v_amount, now()
    );
  END IF;

  -- Ensure winner can take the club
  UPDATE public.gpsl_owner_registry
  SET status = 'awaiting_club_auction',
      pending_starting_balance = greatest(
        coalesce(pending_starting_balance, 0),
        v_amount,
        coalesce(public.club_auction_default_starting_balance(), 650000000)
      ),
      status_changed_at = now()
  WHERE owner_id = v_winner
    AND status IS DISTINCT FROM 'archived'
    AND NOT EXISTS (
      SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v_winner
    );

  BEGIN
    PERFORM public.transferengine_accept_club_auction_sale(v_listing.id);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;

  SELECT c.owner_id INTO v_owner
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  SELECT status, transfer_completed, winning_owner_id, winning_bid
  INTO v_listing.status, v_listing.transfer_completed, v_listing.winning_owner_id, v_listing.winning_bid
  FROM public."Club_Auction_Listings"
  WHERE id = v_listing.id;

  RETURN v_diag || jsonb_build_object(
    'ok', (v_owner IS NOT NULL AND coalesce(v_listing.transfer_completed, false)),
    'action', 'settle_attempted',
    'accept_error', v_err,
    'after_owner_id', v_owner,
    'after_status', v_listing.status,
    'after_transfer_completed', v_listing.transfer_completed,
    'after_winning_owner_id', v_listing.winning_owner_id,
    'after_winning_bid', v_listing.winning_bid
  );
END;
$function$;

-- Force-assign when bid history is gone but you know the buyer email
CREATE OR REPLACE FUNCTION public.admin_force_club_auction_assign(
  p_owner_email text,
  p_club_short_name text DEFAULT 'SOA',
  p_bid_amount numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_email text := lower(btrim(coalesce(p_owner_email, '')));
  v_club text;
  v_user_id uuid;
  v_listing public."Club_Auction_Listings"%rowtype;
  v_amount numeric;
  v_repair jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_email = '' THEN
    RAISE EXCEPTION 'Owner email is required';
  END IF;

  v_club := public.club_auction_resolve_short_name(p_club_short_name);
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'Club % not found', p_club_short_name;
  END IF;

  SELECT u.id INTO v_user_id
  FROM auth.users u
  WHERE lower(u.email) = v_email
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No auth user with email %', p_owner_email;
  END IF;

  IF v_club IN ('SOA', 'NMU') THEN
    PERFORM public.club_auction_migrate_short_name_orphans('NMU', 'SOA');
    v_club := 'SOA';
  END IF;

  SELECT * INTO v_listing
  FROM public."Club_Auction_Listings" l
  WHERE l.club_short_name = v_club
  ORDER BY
    CASE WHEN coalesce(l.transfer_completed, false) THEN 2
         WHEN l.status = 'Active' THEN 0
         ELSE 1 END,
    l.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    -- Create a listing shell so settle/repair has a row
    INSERT INTO public."Club_Auction_Listings" (
      club_short_name, status, opening_bid, reserve_price, created_at, updated_at
    )
    VALUES (
      v_club,
      'Active',
      coalesce(
        public.club_stadium_infra_purchase_cost(v_club),
        public.club_auction_opening_bid_for_capacity(
          (SELECT coalesce(c."Capacity", 0)::bigint FROM public."Clubs" c WHERE c."ShortName" = v_club)
        ),
        0
      ),
      coalesce(
        public.club_stadium_infra_purchase_cost(v_club),
        0
      ),
      now(),
      now()
    )
    RETURNING * INTO v_listing;
  END IF;

  v_amount := coalesce(
    nullif(p_bid_amount, 0),
    v_listing.current_highest_bid,
    v_listing.opening_bid,
    v_listing.reserve_price,
    public.club_stadium_infra_purchase_cost(v_club),
    0
  );

  UPDATE public."Club_Auction_Listings"
  SET status = 'Active',
      transfer_completed = false,
      current_highest_bid = v_amount,
      current_highest_bidder = v_user_id,
      reserve_price = least(coalesce(reserve_price, v_amount), v_amount),
      updated_at = now()
  WHERE id = v_listing.id;

  INSERT INTO public."Club_Auction_Bids" (
    listing_id, club_short_name, bidder_owner_id, bid_amount, bid_time
  ) VALUES (
    v_listing.id, v_club, v_user_id, v_amount, now()
  );

  INSERT INTO public.gpsl_owner_registry (
    owner_id, status, pending_starting_balance, status_changed_at
  )
  VALUES (
    v_user_id,
    'awaiting_club_auction',
    coalesce(public.club_auction_default_starting_balance(), 650000000),
    now()
  )
  ON CONFLICT (owner_id) DO UPDATE
  SET status = CASE
        WHEN gpsl_owner_registry.status = 'archived' THEN gpsl_owner_registry.status
        ELSE 'awaiting_club_auction'
      END,
      pending_starting_balance = greatest(
        coalesce(gpsl_owner_registry.pending_starting_balance, 0),
        v_amount,
        coalesce(public.club_auction_default_starting_balance(), 650000000)
      ),
      status_changed_at = now()
  WHERE gpsl_owner_registry.status <> 'archived';

  -- Vacate club if somehow owned by this same user already (noop) — block others
  IF EXISTS (
    SELECT 1 FROM public."Clubs" c
    WHERE c."ShortName" = v_club
      AND c.owner_id IS NOT NULL
      AND c.owner_id IS DISTINCT FROM v_user_id
  ) THEN
    RAISE EXCEPTION 'Club % already has a different owner', v_club;
  END IF;

  v_repair := public.admin_repair_club_auction_club(v_club);
  RETURN jsonb_build_object(
    'ok', coalesce((v_repair->>'ok')::boolean, false),
    'forced_owner_email', v_email,
    'forced_owner_id', v_user_id,
    'forced_bid', v_amount,
    'listing_id', v_listing.id,
    'repair', v_repair
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_auction_find_winner(bigint, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_repair_club_auction_club(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_force_club_auction_assign(text, text, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =============================================================================
-- RUN THESE — paste results back if still stuck
-- =============================================================================

-- A) Listings (note current_highest_* — earlier confirm omitted them)
SELECT
  l.id,
  l.club_short_name,
  l.status,
  l.transfer_completed,
  l.opening_bid,
  l.reserve_price,
  l.current_highest_bid,
  l.current_highest_bidder,
  l.winning_bid,
  l.winning_owner_id,
  (SELECT count(*) FROM public."Club_Auction_Bids" b WHERE b.listing_id = l.id) AS bid_count
FROM public."Club_Auction_Listings" l
WHERE l.club_short_name IN ('SOA', 'NMU')
ORDER BY l.id DESC;

-- B) Bid rows
SELECT b.*
FROM public."Club_Auction_Bids" b
WHERE b.club_short_name IN ('SOA', 'NMU')
   OR b.listing_id IN (
     SELECT l.id FROM public."Club_Auction_Listings" l
     WHERE l.club_short_name IN ('SOA', 'NMU')
   )
ORDER BY b.bid_amount DESC, b.bid_time ASC;

-- C) Max bids (often still NMU after rename)
SELECT m.*, r.status, r.owner_tag, r.pending_starting_balance, u.email
FROM public.club_auction_max_bids m
JOIN public.gpsl_owner_registry r ON r.owner_id = m.owner_id
LEFT JOIN auth.users u ON u.id = m.owner_id
WHERE m.club_short_name IN ('SOA', 'NMU')
ORDER BY m.max_amount DESC;

-- D) Owners still waiting for a club
SELECT r.owner_id, r.status, r.owner_tag, r.pending_starting_balance, u.email
FROM public.gpsl_owner_registry r
LEFT JOIN auth.users u ON u.id = r.owner_id
WHERE r.status = 'awaiting_club_auction'
ORDER BY r.status_changed_at DESC NULLS LAST;

-- E) Repair (returns JSON — paste this)
SELECT public.admin_repair_club_auction_club('SOA');

-- F) Confirm
SELECT
  c."ShortName",
  c.owner_id,
  r.status AS registry_status,
  r.owner_tag,
  f.balance,
  l.status AS listing_status,
  l.transfer_completed,
  l.current_highest_bid,
  l.current_highest_bidder,
  l.winning_bid,
  l.winning_owner_id
FROM public."Clubs" c
LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = c.owner_id
LEFT JOIN public."Club_Finances" f ON f.club_name = c."ShortName"
LEFT JOIN LATERAL (
  SELECT *
  FROM public."Club_Auction_Listings" x
  WHERE x.club_short_name = c."ShortName"
  ORDER BY x.id DESC
  LIMIT 1
) l ON true
WHERE c."ShortName" = 'SOA';

-- If E returns no_winner_to_settle, force with the member's email:
-- SELECT public.admin_force_club_auction_assign('owner@example.com', 'SOA', NULL);
