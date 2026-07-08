-- Hotfix: player_new_owner_transfer_list — market_value text/numeric coalesce
-- Run in Supabase SQL Editor if listing fails with:
--   COALESCE types text and integer cannot be matched

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
  v_tw boolean;
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
      'New Owner actions are only available in the pre-season window or the January transfer window';
  END IF;

  SELECT transfer_window_open INTO v_tw
  FROM public.global_settings
  WHERE id = 1;

  IF coalesce(v_tw, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'Transfer window is closed — listings are disabled';
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

NOTIFY pgrst, 'reload schema';
