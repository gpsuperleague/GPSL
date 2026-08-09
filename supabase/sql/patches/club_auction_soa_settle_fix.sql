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

  SELECT * INTO v_listing
  FROM public."Club_Auction_Listings" l
  WHERE l.club_short_name = v_club
  ORDER BY
    CASE l.status WHEN 'Active' THEN 0 WHEN 'Closed' THEN 1 ELSE 2 END,
    l.transfer_completed DESC,
    l.id DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', format('No club auction listing for %s', v_club),
      'migrate', v_migrate
    );
  END IF;

  SELECT c.owner_id INTO v_owner
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  SELECT b.bid_amount, b.bidder_owner_id
  INTO v_amount, v_winner
  FROM public."Club_Auction_Bids" b
  WHERE b.listing_id = v_listing.id
  ORDER BY b.bid_amount DESC, b.bid_time ASC
  LIMIT 1;

  IF v_winner IS NULL THEN
    v_winner := v_listing.current_highest_bidder;
    v_amount := v_listing.current_highest_bid;
  END IF;

  v_diag := jsonb_build_object(
    'club', v_club,
    'listing_id', v_listing.id,
    'listing_status', v_listing.status,
    'transfer_completed', v_listing.transfer_completed,
    'club_owner_id', v_owner,
    'winner_owner_id', v_winner,
    'winning_bid', v_amount,
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

  -- Do not auto-clear a different owner — that needs a conscious admin action.
  IF v_owner IS NOT NULL AND v_winner IS NOT NULL AND v_owner IS DISTINCT FROM v_winner THEN
    RETURN v_diag || jsonb_build_object(
      'ok', false,
      'error', 'club_has_different_owner',
      'hint', 'Clear Clubs.owner_id for this club in SQL if that owner is wrong, then re-run repair.'
    );
  END IF;

  -- Re-open incomplete closed listing so accept_sale can run
  IF v_listing.status IS DISTINCT FROM 'Active' THEN
    IF v_winner IS NULL THEN
      RETURN v_diag || jsonb_build_object(
        'ok', false,
        'error', 'no_winner_to_settle'
      );
    END IF;
    UPDATE public."Club_Auction_Listings"
    SET status = 'Active',
        transfer_completed = false,
        updated_at = now()
    WHERE id = v_listing.id;
  END IF;

  -- Ensure winner can take the club
  IF v_winner IS NOT NULL THEN
    UPDATE public.gpsl_owner_registry
    SET status = 'awaiting_club_auction',
        status_changed_at = now()
    WHERE owner_id = v_winner
      AND status IS DISTINCT FROM 'archived'
      AND NOT EXISTS (
        SELECT 1 FROM public."Clubs" c WHERE c.owner_id = v_winner
      );
  END IF;

  PERFORM public.transferengine_accept_club_auction_sale(v_listing.id);

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
    'after_owner_id', v_owner,
    'after_status', v_listing.status,
    'after_transfer_completed', v_listing.transfer_completed,
    'after_winning_owner_id', v_listing.winning_owner_id,
    'after_winning_bid', v_listing.winning_bid
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_repair_club_auction_club(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Also keep franchise-swap orphans covered next time NMU→SOA is re-run
-- (documentation note: add club_auction_max_bids to swap legacy list)
-- ---------------------------------------------------------------------------

-- Diagnose SOA / NMU before repair
SELECT
  c."ShortName",
  c."Club",
  c.owner_id,
  c."Capacity",
  c.continent,
  c."Nation"
FROM public."Clubs" c
WHERE c."ShortName" IN ('SOA', 'NMU');

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
  l.winning_owner_id
FROM public."Club_Auction_Listings" l
WHERE l.club_short_name IN ('SOA', 'NMU')
ORDER BY l.id DESC;

-- Repair stuck SOA purchase (safe if already complete)
SELECT public.admin_repair_club_auction_club('SOA');

-- Confirm
SELECT
  c."ShortName",
  c."Club",
  c.owner_id,
  r.status AS registry_status,
  r.owner_tag,
  r.last_club_short_name,
  f.balance,
  l.status AS listing_status,
  l.transfer_completed,
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
