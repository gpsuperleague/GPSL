-- =============================================================================
-- Club auction settlement without active league season
-- Club auction runs before Season 1 is active; post_club_ledger required status=active.
-- Run once in Supabase SQL Editor after club_auction.sql.
-- =============================================================================

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
  v_final_balance numeric;
  v_season_id bigint;
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
  v_final_balance := greatest(v_starting - coalesce(v_amount, 0), 0);

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
    SET balance = v_final_balance
    WHERE club_name = v_listing.club_short_name;
  ELSE
    INSERT INTO public."Club_Finances" (club_name, balance)
    VALUES (v_listing.club_short_name, v_final_balance);
  END IF;

  IF v_amount > 0 THEN
    SELECT s.id INTO v_season_id
    FROM public.competition_seasons s
    WHERE s.is_current = true
      AND s.status IN ('active', 'preseason')
    ORDER BY CASE s.status WHEN 'active' THEN 0 ELSE 1 END, s.id DESC
    LIMIT 1;

    IF v_season_id IS NOT NULL THEN
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
        ),
        v_season_id,
        NULL,
        false,
        false
      );
    ELSE
      RAISE NOTICE 'Club auction listing % — no current season; balance set to % without ledger line',
        p_listing_id, v_final_balance;
    END IF;
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

  RAISE NOTICE 'Club auction listing % settled — % to owner % for % (balance %)',
    p_listing_id, v_listing.club_short_name, v_winner, v_amount, v_final_balance;
END;
$function$;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- SQL Editor / service: allow admin_settle without JWT (postgres has no auth.uid)
-- ---------------------------------------------------------------------------

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
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT draft_random_finish_time INTO v_finish
  FROM public.global_settings
  WHERE id = 1;

  SELECT count(*)::int INTO v_before
  FROM public."Club_Auction_Listings"
  WHERE status = 'Active';

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

NOTIFY pgrst, 'reload schema';
