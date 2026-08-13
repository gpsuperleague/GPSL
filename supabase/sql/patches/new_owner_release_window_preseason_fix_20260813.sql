-- =============================================================================
-- New Owner release/list window — fix calendar Pre-Season
--
-- Bug: Nav can show "Pre-Season" while competition_seasons.status = 'active'
-- and no GPSL month is live yet. Window required transfer_window_open for that
-- empty-month case, so first-season release/list stayed greyed out after TW shut.
--
-- Open when:
--   • season status preseason / setup
--   • calendar_phase = pre_season (before June unlocks)
--   • live GPSL month in june / july / august / january
--   • calendar not configured yet on an active season
--
-- list_available_now no longer requires TW during this window (slots are the
-- first-season privilege; TW still gates normal transfer listing elsewhere).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_new_owner_release_window_open()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_status text;
  v_month text;
  v_phase text;
  v_configured boolean;
BEGIN
  SELECT s.id, s.status
  INTO v_season_id, v_status
  FROM public.competition_seasons s
  WHERE s.is_current = true
  ORDER BY s.id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN false;
  END IF;

  -- Create Pre-Season / setup shells
  IF lower(coalesce(v_status, '')) IN ('preseason', 'setup') THEN
    RETURN true;
  END IF;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));

  -- Live GPSL months for first-season owners
  IF v_month IN ('june', 'july', 'august', 'january') THEN
    RETURN true;
  END IF;

  -- Calendar Pre-Season (nav label) while season is already active
  IF to_regclass('public.competition_calendar_status_public') IS NOT NULL THEN
    SELECT st.calendar_phase, coalesce(st.calendar_configured, false)
    INTO v_phase, v_configured
    FROM public.competition_calendar_status_public st
    WHERE st.season_id = v_season_id
    LIMIT 1;

    IF lower(coalesce(v_phase, '')) = 'pre_season' THEN
      RETURN true;
    END IF;

    IF coalesce(v_configured, false) = false AND v_month = '' THEN
      RETURN true;
    END IF;
  ELSIF v_month = '' THEN
    -- No calendar status view: treat empty month on active season as pre-season
    RETURN true;
  END IF;

  RETURN false;
END;
$function$;

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
  v_eligible boolean;
  v_window boolean;
  v_tw boolean;
  v_active_listings int;
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
    AND l.status IN ('Active', 'Review', 'Seller Review');

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
    -- List uses the same first-season window (not gated on TW)
    'list_available_now', (v_eligible AND v_window)
  );
END;
$function$;

-- Transfer list: same first-season window (do not require global TW)
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
  v_end timestamptz;
  v_listing_id bigint;
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
      AND l.status IN ('Active', 'Review', 'Seller Review')
  ) THEN
    RAISE EXCEPTION 'This player already has an active New Owner transfer listing';
  END IF;

  v_mv := greatest(coalesce(v_player.market_value::numeric, 0::numeric), 0::numeric);
  IF v_mv <= 0 THEN
    RAISE EXCEPTION 'Player has no market value';
  END IF;

  v_remaining := public.club_new_owner_slot_consume(v_club);

  v_end := public.compute_standard_listing_end_time(v_now);

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false,
      winning_bid = null,
      winning_club = null
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'expired', 'Review', 'Seller Review');

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
    v_now,
    v_end,
    'Active',
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
    'new_owner_slots_remaining', v_remaining
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_new_owner_release_window_open() TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_new_owner_release_state() TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_new_owner_transfer_list(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Quick check:
-- SELECT public.club_new_owner_release_window_open();
-- SELECT public.club_new_owner_release_state();
