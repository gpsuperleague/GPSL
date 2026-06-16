-- Welcome inbox when a club is linked (admin assign or club auction win).
-- Backfill for owners who already have a club but no welcome message.
-- Run after owner_inbox_notifications.sql and club_assignment_stadium_charge.sql.

-- 3-arg version superseded the old (uuid, text) overload; drop it or calls are ambiguous.
DROP FUNCTION IF EXISTS public.owner_inbox_send_welcome(uuid, text);

CREATE OR REPLACE FUNCTION public.owner_inbox_send_welcome(
  p_owner_id uuid,
  p_club_short_name text DEFAULT NULL,
  p_created_at timestamptz DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club_name text;
  v_body text;
  v_id bigint;
  v_dedupe text;
BEGIN
  IF p_club_short_name IS NOT NULL THEN
    SELECT c."Club" INTO v_club_name
    FROM public."Clubs" c
    WHERE c."ShortName" = upper(trim(p_club_short_name));

    v_body := format(
      E'Welcome to GPSL — you are now linked to %s.\n\nRead Learning GPSL for navigation, auctions, contracts, matchday, and club expectations.',
      coalesce(v_club_name, upper(trim(p_club_short_name)))
    );
    v_dedupe := 'welcome:' || upper(trim(p_club_short_name));

    IF EXISTS (SELECT 1 FROM public.competition_inbox i WHERE i.dedupe_key = v_dedupe) THEN
      RETURN NULL;
    END IF;

    INSERT INTO public.competition_inbox (
      recipient_club_short_name, owner_id, message_type,
      title, body, action_href, dedupe_key, created_at
    )
    VALUES (
      upper(trim(p_club_short_name)),
      NULL,
      'welcome_gpsl',
      'Welcome to GPSL',
      v_body,
      'learning_gpsl.html',
      v_dedupe,
      coalesce(p_created_at, now())
    )
    RETURNING id INTO v_id;

    RETURN v_id;
  END IF;

  v_body := E'Welcome to GPSL.\n\nYou are registered for the club auction. Read Learning GPSL while you wait — it covers navigation, auctions, contracts, and what is expected of owners.';
  v_dedupe := 'welcome:owner:' || p_owner_id::text;

  IF EXISTS (SELECT 1 FROM public.competition_inbox i WHERE i.dedupe_key = v_dedupe) THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.competition_inbox (
    recipient_club_short_name, owner_id, message_type,
    title, body, action_href, dedupe_key, created_at
  )
  VALUES (
    NULL,
    p_owner_id,
    'welcome_gpsl',
    'Welcome to GPSL',
    v_body,
    'learning_gpsl.html',
    v_dedupe,
    coalesce(p_created_at, now())
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_inbox_backfill_club_welcome(
  p_backdate timestamptz DEFAULT NULL,
  p_club_short_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_backdate timestamptz;
  v_sent int := 0;
  v_skipped int := 0;
  v_id bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT s.started_at INTO v_backdate
  FROM public.competition_seasons s
  WHERE s.is_current = true AND s.status = 'active'
  ORDER BY s.started_at DESC NULLS LAST
  LIMIT 1;

  v_backdate := coalesce(p_backdate, v_backdate, now());

  FOR v_club IN
    SELECT c."ShortName" AS short_name, c.owner_id
    FROM public."Clubs" c
    WHERE c.owner_id IS NOT NULL
      AND c."ShortName" <> 'FOREIGN'
      AND (p_club_short_name IS NULL OR c."ShortName" = upper(trim(p_club_short_name)))
    ORDER BY c."ShortName"
  LOOP
    v_id := public.owner_inbox_send_welcome(v_club.owner_id, v_club.short_name, v_backdate);
    IF v_id IS NOT NULL THEN
      v_sent := v_sent + 1;
    ELSE
      v_skipped := v_skipped + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'sent', v_sent,
    'skipped', v_skipped,
    'backdate', v_backdate
  );
END;
$function$;

-- Club auction settlement — welcome on win
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

  PERFORM public.owner_inbox_send_welcome(v_winner, v_listing.club_short_name);

  RAISE NOTICE 'Club auction listing % settled — % to owner % for % (stadium %)',
    p_listing_id, v_listing.club_short_name, v_winner, v_amount, v_stadium;
END;
$function$;

-- Admin assign — welcome when linking owner to a club
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

  PERFORM public.owner_inbox_send_welcome(v_user_id, v_short);

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

GRANT EXECUTE ON FUNCTION public.owner_inbox_send_welcome(uuid, text, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.owner_inbox_backfill_club_welcome(timestamptz, text) TO authenticated;

-- Backfill all owned clubs (uses active season started_at unless you pass a date):
-- SELECT public.owner_inbox_backfill_club_welcome(NULL, NULL);
--
-- One club, custom backdate:
-- SELECT public.owner_inbox_backfill_club_welcome('2026-06-01 19:00:00+01'::timestamptz, 'URD');
