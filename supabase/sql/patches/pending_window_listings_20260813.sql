-- =============================================================================
-- Pending Window listings — clock starts when transfer window opens
--
-- Standard listings created while transfer_window_open is false are stored as
-- status = 'Pending Window' (no auction clock). When an admin opens the window,
-- they become Active with start/end times from compute_standard_listing_end_time
-- (24h minimum + 7pm UK rule) measured from the open instant.
--
-- Draft / direct listings are not deferred.
-- Discord "LISTED" posts when the listing becomes Active (insert or activate).
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- Depends on: compute_standard_listing_end_time (recalc_standard_listing_end_times.sql)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.compute_standard_listing_end_time(p_start timestamptz)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $function$
DECLARE
  v_min_end   timestamptz;
  v_uk_local  timestamp;
  v_uk_date   date;
  v_uk_time   time;
  v_next19    timestamptz;
  v_add_day   int;
BEGIN
  IF p_start IS NULL THEN
    RETURN NULL;
  END IF;

  v_min_end := p_start + interval '24 hours';
  v_uk_local := v_min_end AT TIME ZONE 'Europe/London';
  v_uk_date := v_uk_local::date;
  v_uk_time := v_uk_local::time;

  IF EXTRACT(HOUR FROM v_uk_time) > 19
     OR (
       EXTRACT(HOUR FROM v_uk_time) = 19
       AND (
         EXTRACT(MINUTE FROM v_uk_time) > 0
         OR EXTRACT(SECOND FROM v_uk_time) > 0
       )
     )
  THEN
    v_add_day := 1;
  ELSE
    v_add_day := 0;
  END IF;

  v_next19 :=
    ((v_uk_date + v_add_day)::timestamp + time '19:00:00')
    AT TIME ZONE 'Europe/London';

  IF v_min_end > v_next19 THEN
    RETURN v_min_end;
  END IF;
  RETURN v_next19;
END;
$function$;

-- ---------------------------------------------------------------------------
-- BEFORE INSERT: defer standard listings while TW is shut
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_player_transfer_listings_defer_until_window()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_open boolean;
BEGIN
  IF current_setting('gpsl.bypass_bid_owner_check', true) = 'on' THEN
    RETURN NEW;
  END IF;

  IF lower(coalesce(NEW.listing_type::text, '')) IN ('draft', 'direct') THEN
    RETURN NEW;
  END IF;

  SELECT coalesce(transfer_window_open, false)
  INTO v_open
  FROM public.global_settings
  WHERE id = 1;

  IF coalesce(v_open, false) THEN
    RETURN NEW;
  END IF;

  NEW.status := 'Pending Window';
  NEW.start_time := NULL;
  NEW.end_time := NULL;
  NEW.initial_end_time := NULL;
  NEW.seller_review_deadline := NULL;
  NEW.review_deadline := NULL;
  NEW.hour_extended := false;
  NEW.was_extended := false;
  NEW.extension_type := 'none';
  NEW.extension_count := 0;
  NEW.extension_state := 'none';
  NEW.last_extension_time := NULL;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_listings_defer_until_window
  ON public."Player_Transfer_Listings";

CREATE TRIGGER player_transfer_listings_defer_until_window
  BEFORE INSERT ON public."Player_Transfer_Listings"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_player_transfer_listings_defer_until_window();

-- ---------------------------------------------------------------------------
-- Activate all Pending Window listings (clock starts now)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.activate_pending_window_listings(
  p_now timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_now timestamptz := coalesce(p_now, now());
  v_end timestamptz;
  v_count int := 0;
BEGIN
  v_end := public.compute_standard_listing_end_time(v_now);

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Active',
      start_time = v_now,
      end_time = v_end,
      initial_end_time = v_end,
      seller_review_deadline = v_end,
      review_deadline = v_end,
      hour_extended = false,
      was_extended = false,
      extension_type = 'none',
      extension_count = 0,
      extension_state = 'none',
      last_extension_time = null
  WHERE l.status = 'Pending Window'
    AND lower(coalesce(l.listing_type::text, '')) IS DISTINCT FROM 'draft'
    AND coalesce(l.transfer_completed, false) = false;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'activated', v_count,
    'start_time', v_now,
    'end_time', v_end
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.activate_pending_window_listings(timestamptz)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.trg_activate_pending_listings_on_window_open()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.transfer_window_open IS TRUE
     AND OLD.transfer_window_open IS NOT TRUE THEN
    BEGIN
      PERFORM public.activate_pending_window_listings(now());
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'activate_pending_window_listings failed: %', SQLERRM;
    END;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_activate_pending_listings_on_window_open
  ON public.global_settings;

CREATE TRIGGER trg_activate_pending_listings_on_window_open
  AFTER UPDATE OF transfer_window_open ON public.global_settings
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_activate_pending_listings_on_window_open();

-- ---------------------------------------------------------------------------
-- Discord LISTED on insert Active OR Pending Window → Active
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_on_listing()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_name text;
  v_club text;
  v_club_full text;
  v_price text;
  v_headline text;
  v_body text;
  v_ask numeric;
  v_source text;
  v_tier text;
  v_age text;
  v_rating text;
  v_was_pending boolean := false;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    v_was_pending := (
      lower(coalesce(OLD.status::text, '')) = 'pending window'
      AND lower(coalesce(NEW.status::text, '')) = 'active'
    );
    IF NOT v_was_pending THEN
      RETURN NEW;
    END IF;
  ELSIF TG_OP = 'INSERT' THEN
    IF lower(coalesce(NEW.status::text, '')) IS DISTINCT FROM 'active' THEN
      RETURN NEW;
    END IF;
  ELSE
    RETURN NEW;
  END IF;

  IF lower(coalesce(NEW.listing_type::text, '')) = 'draft' THEN
    RETURN NEW;
  END IF;

  SELECT
    p."Name",
    nullif(btrim(p."Age"::text), ''),
    nullif(btrim(p."Rating"::text), '')
  INTO v_name, v_age, v_rating
  FROM public."Players" p
  WHERE p."Konami_ID"::text = NEW.player_id::text
  LIMIT 1;

  v_name := coalesce(nullif(btrim(v_name), ''), 'Player ' || NEW.player_id::text);
  v_club := coalesce(nullif(btrim(NEW.seller_club_id), ''), 'Unknown');

  BEGIN
    v_club_full := public.gpsl_discord_feed_club_name(v_club);
  EXCEPTION WHEN OTHERS THEN
    v_club_full := v_club;
  END;

  v_ask := coalesce(NEW.reserve_price, NEW.market_value, 0);

  BEGIN
    v_price := public.transfer_format_money(v_ask);
  EXCEPTION WHEN OTHERS THEN
    v_price := v_ask::text;
  END;

  v_source := lower(coalesce(NEW.special_rules ->> 'source', ''));
  v_tier := lower(coalesce(NEW.special_rules ->> 'tier', ''));

  IF v_source = 'underperformance' THEN
    v_headline := format('🚪 TRANSFER REQUEST — %s', v_name);
    v_body := format(
      E'%s has handed in a transfer request at %s.\nListed at market value: %s\n%s · Age %s · Rating %s\nPerpetual listing until sold.',
      v_name,
      v_club_full,
      v_price,
      CASE v_tier
        WHEN 'big' THEN 'Big club underperformance'
        WHEN 'medium' THEN 'Medium club underperformance'
        ELSE 'Club underperformance'
      END,
      coalesce(v_age, '?'),
      coalesce(v_rating, '?')
    );

    PERFORM public.gpsl_discord_feed_enqueue(
      'transfer_request',
      v_headline,
      v_body,
      15105570,
      'transfer_request:' || NEW.id::text,
      jsonb_build_object(
        'listing_id', NEW.id,
        'player_id', NEW.player_id,
        'club', v_club,
        'source', 'underperformance',
        'tier', v_tier,
        'channel', 'news'
      )
    );

    RETURN NEW;
  END IF;

  v_headline := format('📋 LISTED — %s', v_name);
  v_body := format('Club: %s\nAsking: %s', v_club_full, v_price);

  PERFORM public.gpsl_discord_feed_enqueue(
    'listing',
    v_headline,
    v_body,
    16763904,
    'listing:' || NEW.id::text,
    jsonb_build_object(
      'listing_id', NEW.id,
      'player_id', NEW.player_id,
      'channel', 'news'
    )
  );

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_listing ON public."Player_Transfer_Listings";
DROP TRIGGER IF EXISTS trg_gpsl_discord_feed_listing_activate ON public."Player_Transfer_Listings";

CREATE TRIGGER trg_gpsl_discord_feed_listing
  AFTER INSERT ON public."Player_Transfer_Listings"
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_listing();

CREATE TRIGGER trg_gpsl_discord_feed_listing_activate
  AFTER UPDATE OF status ON public."Player_Transfer_Listings"
  FOR EACH ROW
  EXECUTE FUNCTION public.gpsl_discord_feed_on_listing();

-- ---------------------------------------------------------------------------
-- New Owner list: treat Pending Window as an active slot listing
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.player_new_owner_transfer_list(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_pid text := btrim(p_player_id);
  v_player public."Players"%rowtype;
  v_remaining int;
  v_assigned bigint;
  v_season_id bigint;
  v_mv numeric;
  v_now timestamptz := now();
  v_start timestamptz;
  v_end timestamptz;
  v_listing_id bigint;
  v_tw boolean;
  v_status text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  IF NOT public.club_new_owner_release_window_open() THEN
    RAISE EXCEPTION
      'New Owner actions are only available in pre-season, June–August, or January';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  SELECT c.owner_assigned_season_id
  INTO v_assigned
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club
  FOR UPDATE;

  IF v_assigned IS NULL OR v_season_id IS NULL OR v_assigned <> v_season_id THEN
    RAISE EXCEPTION
      'New Owner actions are only available in your first season in charge of this club';
  END IF;

  SELECT * INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at your club';
  END IF;

  PERFORM public.assert_player_new_owner_listable(v_pid);

  IF EXISTS (
    SELECT 1
    FROM public."Player_Transfer_Listings" l
    WHERE l.player_id::text = v_pid
      AND l.seller_club_id = v_club
      AND coalesce(l.new_owner_slot, false) = true
      AND coalesce(l.new_owner_slot_settled, false) = false
      AND l.status IN ('Active', 'Pending Window', 'Review', 'Seller Review')
  ) THEN
    RAISE EXCEPTION 'This player already has an active New Owner transfer listing';
  END IF;

  v_mv := greatest(coalesce(v_player.market_value::numeric, 0::numeric), 0::numeric);
  IF v_mv <= 0 THEN
    RAISE EXCEPTION 'Player has no market value';
  END IF;

  v_remaining := public.club_new_owner_slot_consume(v_club);

  SELECT coalesce(transfer_window_open, false) INTO v_tw
  FROM public.global_settings
  WHERE id = 1;

  IF coalesce(v_tw, false) THEN
    v_status := 'Active';
    v_start := v_now;
    v_end := public.compute_standard_listing_end_time(v_now);
  ELSE
    v_status := 'Pending Window';
    v_start := NULL;
    v_end := NULL;
  END IF;

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false,
      winning_bid = null,
      winning_club = null
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Pending Window', 'expired', 'Review', 'Seller Review');

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
    new_owner_slot,
    new_owner_slot_settled
  )
  VALUES (
    v_pid,
    v_club,
    v_mv,
    v_mv,
    v_start,
    v_end,
    v_status,
    'standard',
    false,
    null,
    jsonb_build_object('new_owner_list', true),
    null,
    null,
    v_end,
    v_end,
    null,
    null,
    false,
    false,
    false,
    false,
    'none',
    0,
    v_end,
    'none',
    null,
    true,
    false
  )
  RETURNING id INTO v_listing_id;

  RETURN jsonb_build_object(
    'ok', true,
    'listing_id', v_listing_id,
    'player_id', v_pid,
    'player_name', v_player."Name",
    'reserve_price', v_mv,
    'end_time', v_end,
    'status', v_status,
    'new_owner_slots_remaining', v_remaining
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.player_new_owner_transfer_list(text) TO authenticated;

-- Also count Pending Window in new-owner release state active listings
CREATE OR REPLACE FUNCTION public.club_new_owner_release_state()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_season_id bigint;
  v_assigned bigint;
  v_remaining int;
  v_active_listings int;
  v_eligible boolean;
  v_window boolean;
  v_tw boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RAISE EXCEPTION 'No club linked to this account';
  END IF;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  SELECT c.owner_assigned_season_id, c.new_owner_releases_remaining
  INTO v_assigned, v_remaining
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club;

  SELECT count(*)::int INTO v_active_listings
  FROM public."Player_Transfer_Listings" l
  WHERE l.seller_club_id = v_club
    AND coalesce(l.new_owner_slot, false) = true
    AND coalesce(l.new_owner_slot_settled, false) = false
    AND l.status IN ('Active', 'Pending Window', 'Review', 'Seller Review');

  SELECT transfer_window_open INTO v_tw
  FROM public.global_settings
  WHERE id = 1;

  v_eligible := public.club_is_new_owner_release_eligible(v_club);
  v_window := public.club_new_owner_release_window_open();

  RETURN jsonb_build_object(
    'club_shortname', v_club,
    'new_owner_releases_remaining', coalesce(v_remaining, 0),
    'new_owner_slots_remaining', coalesce(v_remaining, 0),
    'max_total', 3,
    'active_new_owner_listings', coalesce(v_active_listings, 0),
    'owner_assigned_season_id', v_assigned,
    'current_season_id', v_season_id,
    'first_season_at_club', (v_assigned IS NOT NULL AND v_season_id IS NOT NULL AND v_assigned = v_season_id),
    'eligible', v_eligible,
    'window_open', v_window,
    'transfer_window_open', coalesce(v_tw, false),
    'available_now', (v_eligible AND v_window),
    'list_available_now', (v_eligible AND v_window)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_new_owner_release_state() TO authenticated;

-- ---------------------------------------------------------------------------
-- Repair: if TW is currently shut, freeze already-Active standard listings
-- with no competing bids (pre-window countdown must not run)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_open boolean;
BEGIN
  SELECT coalesce(transfer_window_open, false)
  INTO v_open
  FROM public.global_settings
  WHERE id = 1;

  IF coalesce(v_open, false) THEN
    RETURN;
  END IF;

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Pending Window',
      start_time = NULL,
      end_time = NULL,
      initial_end_time = NULL,
      seller_review_deadline = NULL,
      review_deadline = NULL,
      hour_extended = false,
      was_extended = false,
      extension_type = 'none',
      extension_count = 0,
      extension_state = 'none',
      last_extension_time = NULL
  WHERE l.status = 'Active'
    AND lower(coalesce(l.listing_type::text, '')) IS DISTINCT FROM 'draft'
    AND lower(coalesce(l.listing_type::text, '')) IS DISTINCT FROM 'direct'
    AND coalesce(l.transfer_completed, false) = false
    AND NOT EXISTS (
      SELECT 1
      FROM public."Player_Transfer_Bids" b
      WHERE b.listing_id = l.id
        AND upper(btrim(coalesce(b.bidder_club_id::text, '')))
            IS DISTINCT FROM upper(btrim(coalesce(l.seller_club_id::text, '')))
    );
END $$;

-- Clearer Discord copy when the window opens (pending listings activate)
CREATE OR REPLACE FUNCTION public.gpsl_discord_notify_transfer_window(p_open boolean)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_id bigint;
  v_ts text := to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYYMMDDHH24MI');
BEGIN
  IF p_open THEN
    v_id := public.gpsl_discord_feed_enqueue_notification(
      'notification',
      '🪟 TRANSFER WINDOW OPEN',
      'The transfer window is now open. Pre-listed players are now live with a full auction clock. List, bid, and watch the market.',
      5793266,
      'transfer_window_open:' || v_ts,
      jsonb_build_object('kind', 'transfer_window', 'open', true)
    );
  ELSE
    v_id := public.gpsl_discord_feed_enqueue_notification(
      'notification',
      '🪟 TRANSFER WINDOW CLOSED',
      'The transfer window is now shut. You can still list players; bidding and auction clocks start when it reopens.',
      10038562,
      'transfer_window_closed:' || v_ts,
      jsonb_build_object('kind', 'transfer_window', 'open', false)
    );
  END IF;

  RETURN v_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.gpsl_discord_notify_transfer_window(boolean)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
