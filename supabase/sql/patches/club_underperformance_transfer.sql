-- Big / medium club underperformance — player requests transfer (forced perpetual listing at MV)
-- Run once in Supabase SQL Editor after:
--   competition_club_stadium_attendance.sql (or stadium_attendance_v2.sql)
--   recalc_standard_listing_end_times.sql
--   owner_inbox_notifications.sql
--
-- Hooks into competition_admin_archive_season_with_inbox (season end).
-- Or run manually: SELECT club_underperformance_process_season_with_inbox(season_id);

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

ALTER TABLE public."Player_Transfer_Listings"
  ADD COLUMN IF NOT EXISTS perpetual_renew boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS player_transfer_listings_perpetual_active_idx
  ON public."Player_Transfer_Listings" (seller_club_id, perpetual_renew)
  WHERE perpetual_renew = true AND status IN ('Active', 'Review', 'Seller Review');

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.player_rating_numeric(p_rating text)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_rating IS NULL OR btrim(p_rating) = '' THEN NULL::numeric
    ELSE btrim(p_rating)::numeric
  END;
$$;

CREATE OR REPLACE FUNCTION public.player_age_numeric(p_age text)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_age IS NULL OR btrim(p_age) = '' THEN NULL::numeric
    ELSE btrim(p_age)::numeric
  END;
$$;

CREATE OR REPLACE FUNCTION public.club_underperformance_missed_expectation(
  p_club_short_name text,
  p_season_id bigint
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_tier text;
  v_metrics jsonb;
  v_band text;
BEGIN
  v_tier := public.competition_club_tier(p_club_short_name);

  IF v_tier = 'low' THEN
    RETURN false;
  END IF;

  v_metrics := public.competition_stadium_season_metrics(
    p_club_short_name,
    p_season_id,
    NULL
  );

  IF v_metrics ? 'error' THEN
    RETURN false;
  END IF;

  v_band := coalesce(v_metrics ->> 'performance_band', '');

  RETURN v_band IS DISTINCT FROM 'on_target';
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_underperformance_pick_player(
  p_club_short_name text,
  p_tier text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player_id text;
BEGIN
  IF p_tier = 'big' THEN
    SELECT p."Konami_ID"::text
    INTO v_player_id
    FROM (
      SELECT p2."Konami_ID", public.player_rating_numeric(p2."Rating"::text) AS rnk
      FROM public."Players" p2
      WHERE public.player_contracted_club_key(p2."Contracted_Team") = p_club_short_name
      ORDER BY rnk DESC NULLS LAST, p2."Konami_ID"
      LIMIT 4
    ) top4
    JOIN public."Players" p ON p."Konami_ID" = top4."Konami_ID"
    WHERE NOT EXISTS (
      SELECT 1
      FROM public."Player_Transfer_Listings" l
      WHERE l.player_id = p."Konami_ID"::text
        AND l.perpetual_renew = true
        AND l.status IN ('Active', 'Review', 'Seller Review')
    )
    ORDER BY random()
    LIMIT 1;

  ELSIF p_tier = 'medium' THEN
    SELECT p."Konami_ID"::text
    INTO v_player_id
    FROM public."Players" p
    WHERE public.player_contracted_club_key(p."Contracted_Team") = p_club_short_name
      AND public.player_rating_numeric(p."Rating"::text) BETWEEN 74 AND 78
      AND public.player_age_numeric(p."Age"::text) > 21
      AND NOT EXISTS (
        SELECT 1
        FROM public."Player_Transfer_Listings" l
        WHERE l.player_id = p."Konami_ID"::text
          AND l.perpetual_renew = true
          AND l.status IN ('Active', 'Review', 'Seller Review')
      )
    ORDER BY random()
    LIMIT 1;
  END IF;

  RETURN v_player_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_underperformance_create_listing(
  p_club_short_name text,
  p_player_id text,
  p_season_id bigint,
  p_tier text,
  p_metrics jsonb DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_pid text := btrim(p_player_id);
  v_mv numeric;
  v_max numeric;
  v_now timestamptz := now();
  v_end timestamptz;
  v_listing_id bigint;
  v_player public."Players"%rowtype;
BEGIN
  IF v_club = '' OR v_pid = '' THEN
    RETURN NULL;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public."Player_Transfer_Listings" l
    WHERE l.seller_club_id = v_club
      AND l.perpetual_renew = true
      AND coalesce(l.special_rules ->> 'source', '') = 'underperformance'
      AND coalesce((l.special_rules ->> 'season_id')::bigint, 0) = coalesce(p_season_id, 0)
      AND l.status IN ('Active', 'Review', 'Seller Review')
  ) THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_player
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_pid
    AND public.player_contracted_club_key(p."Contracted_Team") = v_club;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  v_mv := greatest(coalesce(v_player.market_value::numeric, 0), 0);
  v_max := greatest(coalesce(v_player."Maximum_Reserve_Price"::numeric, v_mv), v_mv);
  v_end := public.compute_standard_listing_end_time(v_now);

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false
  WHERE l.player_id = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Review', 'Seller Review', 'expired');

  INSERT INTO public."Player_Transfer_Listings" (
    player_id,
    seller_club_id,
    reserve_price,
    market_value,
    start_time,
    end_time,
    status,
    listing_type,
    hidden_bids,
    random_end_time,
    special_rules,
    current_highest_bid,
    current_highest_bidder,
    seller_review_deadline,
    review_deadline,
    winning_bid,
    winning_club,
    transfer_completed,
    archived,
    hour_extended,
    was_extended,
    extension_type,
    extension_count,
    initial_end_time,
    extension_state,
    last_extension_time,
    perpetual_renew
  )
  VALUES (
    v_pid,
    v_club,
    v_mv,
    v_mv,
    v_now,
    v_end,
    'Active',
    'standard',
    false,
    NULL,
    jsonb_build_object(
      'source', 'underperformance',
      'tier', p_tier,
      'season_id', p_season_id,
      'expected_position', p_metrics ->> 'expected_position',
      'actual_position', p_metrics ->> 'actual_position',
      'performance_band', p_metrics ->> 'performance_band',
      'performance_gap', p_metrics ->> 'performance_gap'
    ),
    NULL,
    NULL,
    v_end,
    v_end,
    NULL,
    NULL,
    false,
    false,
    false,
    false,
    'none',
    0,
    v_end,
    'none',
    NULL,
    true
  )
  RETURNING id INTO v_listing_id;

  RETURN v_listing_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.owner_inbox_notify_underperformance_transfer(
  p_club_short_name text,
  p_player_id text,
  p_listing_id bigint,
  p_tier text,
  p_metrics jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player public."Players"%rowtype;
  v_body text;
  v_exp text;
  v_act text;
BEGIN
  SELECT * INTO v_player
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);

  IF NOT FOUND THEN
    RETURN;
  END IF;

  v_exp := coalesce(p_metrics ->> 'expected_position', '?');
  v_act := coalesce(p_metrics ->> 'actual_position', '?');

  v_body := concat_ws(
    E'\n',
    format(
      '%s has requested a transfer — your club missed its %s-club season expectation.',
      coalesce(v_player."Name", 'A player'),
      p_tier
    ),
    format('Expected league position: %s · Finished: %s · Band: %s',
      v_exp,
      v_act,
      coalesce(p_metrics ->> 'performance_band', 'under')
    ),
    format(
      'Listed at market value (₿ %s) with automatic relisting until sold. You cannot remove this listing.',
      to_char(greatest(coalesce(v_player.market_value::numeric, 0), 0), 'FM999,999,999,999')
    ),
    'See Transfer Centre → Active listings and the Transfer Market.'
  );

  PERFORM public.owner_inbox_send(
    'underperformance_transfer',
    'Player transfer request (underperformance)',
    v_body,
    p_club_short_name,
    NULL,
    NULL, NULL, NULL,
    p_listing_id,
    'transfer_center.html',
    'underperformance:' || p_club_short_name || ':' || coalesce((p_metrics ->> 'season_id'), '0') || ':' || btrim(p_player_id),
    NULL,
    (p_metrics ->> 'season_id')::bigint
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_underperformance_process_club(
  p_club_short_name text,
  p_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_tier text;
  v_metrics jsonb;
  v_player_id text;
  v_listing_id bigint;
BEGIN
  v_tier := public.competition_club_tier(p_club_short_name);

  IF v_tier = 'low' THEN
    RETURN jsonb_build_object('club', p_club_short_name, 'skipped', 'low_tier');
  END IF;

  IF NOT public.club_underperformance_missed_expectation(p_club_short_name, p_season_id) THEN
    RETURN jsonb_build_object('club', p_club_short_name, 'skipped', 'on_target');
  END IF;

  v_metrics := public.competition_stadium_season_metrics(p_club_short_name, p_season_id, NULL);
  v_player_id := public.club_underperformance_pick_player(p_club_short_name, v_tier);

  IF v_player_id IS NULL THEN
    RETURN jsonb_build_object(
      'club', p_club_short_name,
      'tier', v_tier,
      'skipped', 'no_eligible_player'
    );
  END IF;

  v_listing_id := public.club_underperformance_create_listing(
    p_club_short_name,
    v_player_id,
    p_season_id,
    v_tier,
    v_metrics
  );

  IF v_listing_id IS NULL THEN
    RETURN jsonb_build_object('club', p_club_short_name, 'tier', v_tier, 'skipped', 'listing_exists');
  END IF;

  PERFORM public.owner_inbox_notify_underperformance_transfer(
    p_club_short_name,
    v_player_id,
    v_listing_id,
    v_tier,
    v_metrics || jsonb_build_object('season_id', p_season_id)
  );

  RETURN jsonb_build_object(
    'club', p_club_short_name,
    'tier', v_tier,
    'player_id', v_player_id,
    'listing_id', v_listing_id,
    'performance_band', v_metrics ->> 'performance_band'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_underperformance_process_season(p_season_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club record;
  v_results jsonb := '[]'::jsonb;
  v_row jsonb;
  v_triggered int := 0;
BEGIN
  IF p_season_id IS NULL THEN
    RAISE EXCEPTION 'season_id is required';
  END IF;

  FOR v_club IN
    SELECT c."ShortName" AS club_short_name
    FROM public."Clubs" c
    WHERE c."ShortName" <> 'FOREIGN'
      AND c.owner_id IS NOT NULL
    ORDER BY c."ShortName"
  LOOP
    v_row := public.club_underperformance_process_club(v_club.club_short_name, p_season_id);
    v_results := v_results || jsonb_build_array(v_row);

    IF v_row ? 'listing_id' THEN
      v_triggered := v_triggered + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'season_id', p_season_id,
    'triggered_count', v_triggered,
    'results', v_results
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_underperformance_process_season_with_inbox(p_season_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN public.club_underperformance_process_season(p_season_id);
END;
$function$;

-- ---------------------------------------------------------------------------
-- Perpetual relist + transfer engine integration
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.transferengine_perpetual_relist(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Player_Transfer_Listings"%rowtype;
  v_player public."Players"%rowtype;
  v_mv numeric;
  v_now timestamptz := now();
  v_end timestamptz;
BEGIN
  SELECT * INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id
    AND perpetual_renew = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT * INTO v_player
  FROM public."Players" p
  WHERE p."Konami_ID"::text = v_listing.player_id::text;

  IF NOT FOUND
     OR public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_listing.seller_club_id THEN
    UPDATE public."Player_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = false
    WHERE id = p_listing_id;
    RETURN;
  END IF;

  v_mv := greatest(coalesce(v_player.market_value::numeric, 0), 0);
  v_end := public.compute_standard_listing_end_time(v_now);

  UPDATE public."Player_Transfer_Bids"
  SET status = 'rejected'
  WHERE listing_id = p_listing_id
    AND lower(coalesce(status::text, '')) = 'active';

  UPDATE public."Player_Transfer_Listings"
  SET status = 'Active',
      start_time = v_now,
      end_time = v_end,
      initial_end_time = v_end,
      seller_review_deadline = v_end,
      review_deadline = v_end,
      reserve_price = v_mv,
      market_value = v_mv,
      current_highest_bid = NULL,
      current_highest_bidder = NULL,
      winning_bid = NULL,
      winning_club = NULL,
      transfer_completed = false,
      was_extended = false,
      hour_extended = false,
      extension_type = 'none',
      extension_count = 0,
      extension_state = 'none',
      last_extension_time = NULL
  WHERE id = p_listing_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.transferengine_evaluate_expired_listing(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_listing "Player_Transfer_Listings"%rowtype;
  v_now     timestamptz := now();
BEGIN
  SELECT *
  INTO v_listing
  FROM "Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Listing % not found in evaluate_expired_listing', p_listing_id;
    RETURN;
  END IF;

  PERFORM public.transferengine_sync_listing_high_bid(p_listing_id);

  SELECT *
  INTO v_listing
  FROM "Player_Transfer_Listings"
  WHERE id = p_listing_id;

  IF v_listing.current_highest_bid IS NULL THEN
    IF coalesce(v_listing.perpetual_renew, false) THEN
      PERFORM public.transferengine_perpetual_relist(p_listing_id);
    ELSE
      UPDATE "Player_Transfer_Listings"
      SET status = 'Closed',
          transfer_completed = false
      WHERE id = v_listing.id;
    END IF;
    RETURN;
  END IF;

  IF v_listing.current_highest_bid >= v_listing.reserve_price THEN
    PERFORM transferengine_accept_sale(v_listing.id);

    -- If accept_sale aborted (e.g. same-season lock), do not leave Active forever
    IF EXISTS (
      SELECT 1 FROM "Player_Transfer_Listings"
      WHERE id = v_listing.id AND status = 'Active'
    ) THEN
      UPDATE "Player_Transfer_Listings"
      SET status = 'Review',
          seller_review_deadline = v_now + interval '24 hours'
      WHERE id = v_listing.id
        AND status = 'Active';
      RAISE NOTICE
        'Listing % accept_sale did not complete — moved to Review',
        v_listing.id;
    END IF;
    RETURN;
  END IF;

  UPDATE "Player_Transfer_Listings"
  SET status = 'Review',
      seller_review_deadline = v_now + interval '24 hours'
  WHERE id = v_listing.id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.transferengine_reject_sale(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_perpetual boolean;
BEGIN
  SELECT perpetual_renew INTO v_perpetual
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id;

  IF coalesce(v_perpetual, false) THEN
    PERFORM public.transferengine_perpetual_relist(p_listing_id);
    RETURN;
  END IF;

  UPDATE "Player_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = false,
      winning_bid = null,
      winning_club = null
  WHERE id = p_listing_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.transferengine_accept_sale(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_listing          "Player_Transfer_Listings"%rowtype;
  v_buyer_balance    numeric;
  v_seller_balance   numeric;
  v_player           "Players"%rowtype;
BEGIN
  SELECT *
  INTO v_listing
  FROM "Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Listing % not found', p_listing_id;
    RETURN;
  END IF;

  IF v_listing.status NOT IN ('Active', 'Review') THEN
    RAISE NOTICE 'Listing % already processed', p_listing_id;
    RETURN;
  END IF;

  SELECT balance
  INTO v_buyer_balance
  FROM "Club_Finances"
  WHERE club_name = v_listing.current_highest_bidder
  FOR UPDATE;

  SELECT balance
  INTO v_seller_balance
  FROM "Club_Finances"
  WHERE club_name = v_listing.seller_club_id
  FOR UPDATE;

  IF v_buyer_balance IS NULL OR v_seller_balance IS NULL THEN
    RAISE NOTICE 'Finance lookup failed for listing %', p_listing_id;
    RETURN;
  END IF;

  SELECT *
  INTO v_player
  FROM "Players"
  WHERE "Konami_ID"::text = v_listing.player_id::text
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE NOTICE 'Player not found for listing %', p_listing_id;
    RETURN;
  END IF;

  IF v_player."Contracted_Team" IS DISTINCT FROM v_listing.seller_club_id THEN
    RAISE NOTICE 'Player no longer at selling club for listing %', p_listing_id;
    RETURN;
  END IF;

  IF NOT coalesce(v_listing.perpetual_renew, false)
     AND NOT coalesce(v_listing.new_owner_slot, false)
     AND coalesce(v_listing.special_rules ->> 'new_owner_list', '') IS DISTINCT FROM 'true'
     AND public.player_signed_this_season(v_player."Season_Signed") THEN
    RAISE NOTICE 'Player signed this season — sale blocked for listing %', p_listing_id;
    RETURN;
  END IF;

  UPDATE "Club_Finances"
  SET balance = v_buyer_balance - v_listing.current_highest_bid
  WHERE club_name = v_listing.current_highest_bidder;

  UPDATE "Club_Finances"
  SET balance = v_seller_balance + v_listing.current_highest_bid
  WHERE club_name = v_listing.seller_club_id;

  PERFORM public.player_assign_to_club(
    v_listing.player_id::text,
    v_listing.current_highest_bidder,
    NULL::numeric,
    false
  );

  INSERT INTO "Transfer_History" (
    player_id,
    seller_club_id,
    buyer_club_id,
    fee,
    agent_fee,
    transfer_time,
    listing_id
  )
  VALUES (
    v_listing.player_id,
    v_listing.seller_club_id,
    v_listing.current_highest_bidder,
    v_listing.current_highest_bid,
    0,
    now(),
    v_listing.id
  );

  UPDATE "Player_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = true,
      winning_bid = v_listing.current_highest_bid,
      winning_club = v_listing.current_highest_bidder
  WHERE id = v_listing.id;
END;
$function$;

-- Block manual removal of forced listings (UI/API updates to Closed without sale)
CREATE OR REPLACE FUNCTION public.trg_block_perpetual_listing_close()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF TG_OP = 'UPDATE'
     AND coalesce(OLD.perpetual_renew, false)
     AND NEW.status = 'Closed'
     AND NOT coalesce(NEW.transfer_completed, false)
     AND OLD.status IS DISTINCT FROM 'Closed' THEN
    RAISE EXCEPTION
      'This player requested a transfer after club underperformance — the listing relists automatically and cannot be removed manually.';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_listings_perpetual_close_block ON public."Player_Transfer_Listings";
CREATE TRIGGER player_transfer_listings_perpetual_close_block
  BEFORE UPDATE ON public."Player_Transfer_Listings"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_block_perpetual_listing_close();

-- Skip same-season / final-year guards for forced underperformance listings
CREATE OR REPLACE FUNCTION public.trg_listing_block_same_season_sale()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NEW.player_id IS NULL OR btrim(NEW.player_id::text) = '' THEN
    RETURN NEW;
  END IF;

  IF coalesce(NEW.perpetual_renew, false)
     AND coalesce(NEW.special_rules ->> 'source', '') = 'underperformance' THEN
    RETURN NEW;
  END IF;

  PERFORM public.assert_player_transferable(btrim(NEW.player_id::text));
  RETURN NEW;
END;
$function$;

-- Season archive wrapper — run underperformance after standings are archived
CREATE OR REPLACE FUNCTION public.competition_admin_archive_season_with_inbox(p_season_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_result jsonb;
  v_season_id bigint;
  v_label text;
  v_under jsonb;
BEGIN
  v_result := public.competition_admin_archive_season(p_season_id);
  v_season_id := (v_result ->> 'season_id')::bigint;
  v_label := v_result ->> 'season_label';

  IF v_season_id IS NOT NULL THEN
    PERFORM public.owner_inbox_notify_club_season_archive(v_season_id, coalesce(v_label, 'Season'));
    v_under := public.club_underperformance_process_season(v_season_id);
    v_result := v_result || jsonb_build_object('underperformance', v_under);
  END IF;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_underperformance_process_season_with_inbox(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_underperformance_missed_expectation(text, bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';
