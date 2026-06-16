-- =============================================================================
-- Club assignment — stadium infra purchase (capacity × ₿1,000)
-- Matches finances_accounts → Infrastructure purchases / club auction stadium cost.
-- Run after club_auction_capacity_pricing.sql + central_bank_phase1.sql
--        (+ club_auction_settle_no_active_season.sql if already applied)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_finances_current_season_id()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.id
  FROM public.competition_seasons s
  WHERE s.is_current = true
    AND s.status IN ('active', 'preseason')
  ORDER BY CASE s.status WHEN 'active' THEN 0 ELSE 1 END, s.id DESC
  LIMIT 1;
$$;

COMMENT ON FUNCTION public.competition_finances_current_season_id() IS
  'Current season for finance ledger posts (active or preseason).';

CREATE OR REPLACE FUNCTION public.club_stadium_infra_purchase_cost(p_club_short_name text)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.club_auction_opening_bid_for_capacity(
    coalesce(c."Capacity", 0)::bigint
  )
  FROM public."Clubs" c
  WHERE c."ShortName" = upper(btrim(p_club_short_name));
$$;

COMMENT ON FUNCTION public.club_stadium_infra_purchase_cost(text) IS
  'Stadium purchase line on season accounts: capacity × ₿1,000 (same as club auction opening bid).';

-- ---------------------------------------------------------------------------
-- Apply starting budget → club balance after assignment; post infra_purchase ledger
-- p_total_debit: auction winning bid (≥ stadium cost) or NULL → stadium cost only
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.owner_apply_club_assignment_finances(
  p_club_short_name text,
  p_owner_id uuid,
  p_starting_budget numeric,
  p_total_debit numeric DEFAULT NULL,
  p_source text DEFAULT 'club_assignment',
  p_metadata jsonb DEFAULT '{}'::jsonb,
  p_description text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := upper(btrim(p_club_short_name));
  v_stadium numeric;
  v_debit numeric;
  v_starting numeric;
  v_balance numeric;
  v_season_id bigint;
  v_club_name text;
  v_desc text;
  v_meta jsonb;
  v_ledger_id bigint;
  v_dup_key text;
BEGIN
  IF v_club IS NULL OR v_club = '' THEN
    RAISE EXCEPTION 'Club required';
  END IF;

  v_stadium := coalesce(public.club_stadium_infra_purchase_cost(v_club), 0);
  v_debit := coalesce(nullif(p_total_debit, 0), v_stadium);
  v_debit := greatest(v_debit, v_stadium);
  v_starting := greatest(coalesce(p_starting_budget, 0), 0);
  v_balance := greatest(v_starting - v_debit, 0);

  SELECT c."Club" INTO v_club_name
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  v_meta := coalesce(p_metadata, '{}'::jsonb)
    || jsonb_build_object(
      'source', coalesce(nullif(btrim(p_source), ''), 'club_assignment'),
      'owner_id', p_owner_id,
      'stadium_cost', v_stadium,
      'total_debit', v_debit,
      'starting_budget', v_starting
    );

  v_dup_key := coalesce(v_meta->>'listing_id', v_meta->>'assignment_key', p_owner_id::text);

  IF EXISTS (
    SELECT 1 FROM public."Club_Finances" f WHERE f.club_name = v_club
  ) THEN
    UPDATE public."Club_Finances"
    SET balance = v_balance
    WHERE club_name = v_club;
  ELSE
    INSERT INTO public."Club_Finances" (club_name, balance)
    VALUES (v_club, v_balance);
  END IF;

  v_season_id := public.competition_finances_current_season_id();

  IF v_debit > 0 AND v_season_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.competition_finance_ledger l
      WHERE l.club_short_name = v_club
        AND l.season_id = v_season_id
        AND l.entry_type = 'infra_purchase'
        AND coalesce(l.metadata->>'source', '') = coalesce(nullif(btrim(p_source), ''), 'club_assignment')
        AND coalesce(l.metadata->>'dup_key', l.metadata->>'listing_id', '') = v_dup_key
    ) THEN
      v_desc := coalesce(
        nullif(btrim(p_description), ''),
        format(
          'Stadium purchase — %s (%s) — ₿%s (capacity × ₿1,000)',
          coalesce(v_club_name, v_club),
          v_club,
          to_char(v_stadium, 'FM999,999,999,999')
        )
      );

      IF v_debit > v_stadium THEN
        v_desc := v_desc || format(
          ' + auction premium ₿%s',
          to_char(v_debit - v_stadium, 'FM999,999,999,999')
        );
      END IF;

      v_meta := v_meta || jsonb_build_object('dup_key', v_dup_key);

      v_ledger_id := public.post_club_ledger(
        v_club,
        'infra_purchase',
        -v_debit,
        v_desc,
        v_meta,
        v_season_id,
        NULL,
        false,
        false
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'club_short_name', v_club,
    'stadium_cost', v_stadium,
    'total_debit', v_debit,
    'starting_budget', v_starting,
    'balance', v_balance,
    'season_id', v_season_id,
    'ledger_id', v_ledger_id,
    'ledger_skipped_no_season', v_season_id IS NULL AND v_debit > 0
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.competition_finances_current_season_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_stadium_infra_purchase_cost(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_apply_club_assignment_finances(
  text, uuid, numeric, numeric, text, jsonb, text
) TO authenticated;

-- ---------------------------------------------------------------------------
-- Club auction settlement — use stadium cost + winning bid
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

  RAISE NOTICE 'Club auction listing % settled — % to owner % for % (stadium %)',
    p_listing_id, v_listing.club_short_name, v_winner, v_amount, v_stadium;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Admin assign — charge stadium when linking owner to a vacant club
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_assign_club_owner(
  p_owner_email text,
  p_club_short_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_email text := lower(trim(p_owner_email));
  v_short text := upper(trim(p_club_short_name));
  v_user_id uuid;
  v_club_name text;
  v_replaced_previous boolean := false;
  v_registry_status text;
  v_displaced uuid;
  v_old_club text;
  v_tag text;
  v_was_vacant boolean := false;
  v_starting numeric;
  v_pending numeric;
  v_fin jsonb;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_email IS NULL OR v_email = '' THEN
    RAISE EXCEPTION 'Owner email is required';
  END IF;

  IF v_short IS NULL OR v_short = '' THEN
    RAISE EXCEPTION 'Club ShortName is required';
  END IF;

  SELECT u.id INTO v_user_id
  FROM auth.users u
  WHERE lower(u.email) = v_email
  LIMIT 1;

  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No auth user with email %', p_owner_email;
  END IF;

  SELECT r.status, r.pending_starting_balance
  INTO v_registry_status, v_pending
  FROM public.gpsl_owner_registry r
  WHERE r.owner_id = v_user_id;

  IF v_registry_status = 'archived' THEN
    RAISE EXCEPTION 'Owner is archived — unarchive before linking to a club';
  END IF;

  SELECT c."Club", (c.owner_id IS NULL)
  INTO v_club_name, v_was_vacant
  FROM public."Clubs" c
  WHERE c."ShortName" = v_short;

  IF v_club_name IS NULL THEN
    RAISE EXCEPTION 'Club ShortName % not found', v_short;
  END IF;

  SELECT c.owner_id INTO v_displaced
  FROM public."Clubs" c
  WHERE c."ShortName" = v_short
    AND c.owner_id IS NOT NULL
    AND c.owner_id <> v_user_id
  LIMIT 1;

  IF v_displaced IS NOT NULL THEN
    v_replaced_previous := true;
    PERFORM public.admin_owner_detach_core(v_displaced, 'on_break', 'Displaced by admin club link');
    v_was_vacant := true;
  END IF;

  SELECT c."ShortName", nullif(btrim(c.owner), '')
  INTO v_old_club, v_tag
  FROM public."Clubs" c
  WHERE c.owner_id = v_user_id
    AND c."ShortName" <> v_short
  LIMIT 1;

  IF v_old_club IS NOT NULL THEN
    PERFORM public.admin_club_vacate(v_old_club);
  END IF;

  UPDATE public."Clubs"
  SET owner_id = v_user_id,
      owner = coalesce(v_tag, owner)
  WHERE "ShortName" = v_short;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Failed to update club %', v_short;
  END IF;

  IF v_was_vacant THEN
    v_starting := greatest(
      coalesce(nullif(v_pending, 0), public.club_auction_default_starting_balance()),
      0
    );

    v_fin := public.owner_apply_club_assignment_finances(
      v_short,
      v_user_id,
      v_starting,
      NULL,
      'admin_assign',
      jsonb_build_object(
        'assignment_key', v_user_id::text || ':' || v_short,
        'dup_key', v_user_id::text || ':' || v_short
      ),
      format('Club assigned — %s (%s)', v_club_name, v_short)
    );
  END IF;

  INSERT INTO public.gpsl_owner_registry (owner_id, status, owner_tag, last_club_short_name, status_changed_at)
  VALUES (v_user_id, 'active', v_tag, v_short, now())
  ON CONFLICT (owner_id) DO UPDATE
  SET status = 'active',
      owner_tag = coalesce(excluded.owner_tag, gpsl_owner_registry.owner_tag),
      last_club_short_name = v_short,
      pending_starting_balance = CASE
        WHEN v_was_vacant THEN 0
        ELSE gpsl_owner_registry.pending_starting_balance
      END,
      status_note = NULL,
      status_changed_at = now();

  RETURN jsonb_build_object(
    'user_id', v_user_id,
    'email', p_owner_email,
    'club_short_name', v_short,
    'club_name', v_club_name,
    'replaced_previous_owner', v_replaced_previous,
    'from_club_short_name', v_old_club,
    'finances', v_fin
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_assign_club_owner(text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- One-time repair: owned clubs missing infra_purchase (incl. Urawa / URD)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.repair_club_assignment_finances(
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row record;
  v_starting numeric;
  v_debit numeric;
  v_default numeric;
  v_results jsonb := '[]'::jsonb;
  v_fin jsonb;
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_default := public.club_auction_default_starting_balance();

  FOR v_row IN
    SELECT
      c."ShortName" AS club_short_name,
      c.owner_id,
      l.id AS listing_id,
      l.winning_bid,
      reg.pending_starting_balance
    FROM public."Clubs" c
    JOIN public.gpsl_owner_registry reg ON reg.owner_id = c.owner_id
    LEFT JOIN public."Club_Auction_Listings" l
      ON l.club_short_name = c."ShortName"
     AND l.transfer_completed = true
     AND l.winning_owner_id = c.owner_id
    WHERE c.owner_id IS NOT NULL
      AND c."ShortName" <> 'FOREIGN'
      AND (
        p_club_short_name IS NULL
        OR c."ShortName" = upper(btrim(p_club_short_name))
      )
  LOOP
    v_starting := greatest(coalesce(nullif(v_row.pending_starting_balance, 0), v_default), 0);
    v_debit := coalesce(nullif(v_row.winning_bid, 0), public.club_stadium_infra_purchase_cost(v_row.club_short_name));

    v_fin := public.owner_apply_club_assignment_finances(
      v_row.club_short_name,
      v_row.owner_id,
      v_starting,
      v_debit,
      CASE WHEN v_row.listing_id IS NOT NULL THEN 'club_auction' ELSE 'admin_assign' END,
      jsonb_build_object(
        'listing_id', v_row.listing_id::text,
        'assignment_key', v_row.owner_id::text || ':' || v_row.club_short_name,
        'dup_key', coalesce(v_row.listing_id::text, v_row.owner_id::text || ':' || v_row.club_short_name),
        'repair', true
      ),
      NULL
    );

    v_results := v_results || jsonb_build_array(v_fin);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'repaired', jsonb_array_length(v_results), 'clubs', v_results);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.repair_club_assignment_finances(text) TO authenticated;

-- Repair Urawa Reds and any other owned clubs missing the stadium charge
SELECT public.repair_club_assignment_finances('URD');

NOTIFY pgrst, 'reload schema';
