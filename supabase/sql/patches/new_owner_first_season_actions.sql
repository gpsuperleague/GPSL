-- =============================================================================
-- New Owner first-season actions — shared pool of 3 (release OR transfer list)
-- Transfer list uses a slot while active; slot returns if listing ends unsold.
-- Run after: new_owner_release.sql, club_underperformance_transfer.sql
-- =============================================================================

ALTER TABLE public."Player_Transfer_Listings"
  ADD COLUMN IF NOT EXISTS new_owner_slot boolean NOT NULL DEFAULT false;

ALTER TABLE public."Player_Transfer_Listings"
  ADD COLUMN IF NOT EXISTS new_owner_slot_settled boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public."Player_Transfer_Listings".new_owner_slot IS
  'First-season New Owner slot listing — counts against Clubs.new_owner_releases_remaining while active.';
COMMENT ON COLUMN public."Player_Transfer_Listings".new_owner_slot_settled IS
  'Slot accounting settled (sold = consumed; unsold close = restored).';

-- ---------------------------------------------------------------------------
-- Slot helpers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.club_new_owner_slot_consume(p_club_short text)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_remaining int;
BEGIN
  SELECT c."ShortName" INTO v_club
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = upper(btrim(coalesce(p_club_short, '')))
  LIMIT 1;

  IF v_club IS NULL THEN
    RAISE EXCEPTION 'Club not found';
  END IF;

  UPDATE public."Clubs" c
  SET new_owner_releases_remaining = new_owner_releases_remaining - 1
  WHERE c."ShortName" = v_club
    AND coalesce(c.new_owner_releases_remaining, 0) > 0
  RETURNING c.new_owner_releases_remaining INTO v_remaining;

  IF v_remaining IS NULL THEN
    RAISE EXCEPTION 'No New Owner first-season slots remaining (maximum 3)';
  END IF;

  RETURN v_remaining;
END;
$function$;

CREATE OR REPLACE FUNCTION public.club_new_owner_slot_restore(p_club_short text)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_remaining int;
BEGIN
  SELECT c."ShortName" INTO v_club
  FROM public."Clubs" c
  WHERE upper(c."ShortName") = upper(btrim(coalesce(p_club_short, '')))
  LIMIT 1;

  IF v_club IS NULL THEN
    RETURN NULL;
  END IF;

  UPDATE public."Clubs" c
  SET new_owner_releases_remaining = least(3, coalesce(c.new_owner_releases_remaining, 0) + 1)
  WHERE c."ShortName" = v_club
  RETURNING c.new_owner_releases_remaining INTO v_remaining;

  RETURN v_remaining;
END;
$function$;

CREATE OR REPLACE FUNCTION public.new_owner_listing_settle_slot(
  p_listing_id bigint,
  p_sold boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Player_Transfer_Listings"%rowtype;
BEGIN
  SELECT * INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND OR coalesce(v_listing.new_owner_slot, false) IS NOT TRUE THEN
    RETURN;
  END IF;

  IF coalesce(v_listing.new_owner_slot_settled, false) THEN
    RETURN;
  END IF;

  IF p_sold THEN
    UPDATE public."Player_Transfer_Listings"
    SET new_owner_slot_settled = true
    WHERE id = p_listing_id;
    RETURN;
  END IF;

  PERFORM public.club_new_owner_slot_restore(v_listing.seller_club_id);

  UPDATE public."Player_Transfer_Listings"
  SET new_owner_slot_settled = true
  WHERE id = p_listing_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_player_transfer_listings_new_owner_slot()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF coalesce(NEW.new_owner_slot, false) IS NOT TRUE THEN
    RETURN NEW;
  END IF;

  IF coalesce(NEW.new_owner_slot_settled, false) THEN
    RETURN NEW;
  END IF;

  IF coalesce(NEW.transfer_completed, false) IS TRUE
    AND coalesce(OLD.transfer_completed, false) IS DISTINCT FROM TRUE THEN
    PERFORM public.new_owner_listing_settle_slot(NEW.id, true);
    NEW.new_owner_slot_settled := true;
    RETURN NEW;
  END IF;

  IF NEW.status = 'Closed'
    AND coalesce(NEW.transfer_completed, false) IS NOT TRUE
    AND (
      OLD.status IS DISTINCT FROM 'Closed'
      OR coalesce(OLD.transfer_completed, false) IS DISTINCT FROM false
    ) THEN
    PERFORM public.new_owner_listing_settle_slot(NEW.id, false);
    NEW.new_owner_slot_settled := true;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_listings_new_owner_slot ON public."Player_Transfer_Listings";
CREATE TRIGGER player_transfer_listings_new_owner_slot
  BEFORE UPDATE ON public."Player_Transfer_Listings"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_player_transfer_listings_new_owner_slot();

-- ---------------------------------------------------------------------------
-- State (extended)
-- ---------------------------------------------------------------------------

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
    'list_available_now', (v_eligible AND v_window AND coalesce(v_tw, false))
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- New Owner transfer list (standard listing at market value)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.player_new_owner_list_preview(p_player_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_pid text := btrim(p_player_id);
  v_player public."Players"%rowtype;
  v_state jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_club := public.my_club_shortname();
  v_state := public.club_new_owner_release_state();

  SELECT * INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_at_club');
  END IF;

  BEGIN
    PERFORM public.assert_player_new_owner_listable(v_pid);
  EXCEPTION
    WHEN OTHERS THEN
      RETURN jsonb_build_object(
        'ok', false,
        'reason', 'not_transferable',
        'message', SQLERRM
      );
  END;

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'player_name', v_player."Name",
    'market_value', v_player.market_value,
    'club_state', v_state
  );
END;
$function$;

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

-- ---------------------------------------------------------------------------
-- Release — block active new-owner listing; clearer slot messaging
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.player_new_owner_release(p_player_id text)
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
  v_fee numeric;
  v_balance numeric;
  v_unlock text;
  v_ledger_id bigint;
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

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  SELECT c.new_owner_releases_remaining, c.owner_assigned_season_id
  INTO v_remaining, v_assigned
  FROM public."Clubs" c
  WHERE c."ShortName" = v_club
  FOR UPDATE;

  IF v_assigned IS NULL OR v_season_id IS NULL OR v_assigned <> v_season_id THEN
    RAISE EXCEPTION
      'New Owner actions are only available in your first season in charge of this club';
  END IF;

  IF coalesce(v_remaining, 0) <= 0 THEN
    RAISE EXCEPTION 'No New Owner first-season slots remaining (maximum 3 release or transfer list actions)';
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

  IF EXISTS (
    SELECT 1
    FROM public."Player_Transfer_Listings" l
    WHERE l.player_id::text = v_pid
      AND l.seller_club_id = v_club
      AND coalesce(l.new_owner_slot, false) = true
      AND coalesce(l.new_owner_slot_settled, false) = false
      AND l.status IN ('Active', 'Review', 'Seller Review')
  ) THEN
    RAISE EXCEPTION
      'Close or wait for the New Owner transfer listing to finish before releasing this player';
  END IF;

  v_fee := public.club_player_purchase_fee(v_club, v_pid);
  IF v_fee IS NULL OR v_fee <= 0 THEN
    RAISE EXCEPTION
      'No purchase fee found for this player at your club — New Owner release only applies to players the club paid a transfer fee for';
  END IF;

  SELECT balance INTO v_balance
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_balance IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false,
      winning_bid = null,
      winning_club = null
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Review');

  UPDATE public."Player_Transfer_Bids" b
  SET status = 'rejected'
  WHERE b.is_direct = true
    AND b.listing_id IS NULL
    AND lower(coalesce(b.status::text, '')) = 'active'
    AND (
      (b.player_id IS NOT NULL AND btrim(b.player_id::text) = v_pid)
      OR (b.direct_bid_id IS NOT NULL AND btrim(b.direct_bid_id::text) = v_pid)
    );

  PERFORM public.player_release_from_club(v_pid);
  PERFORM public.player_apply_overflow_paid_up_lock(v_pid, v_club);

  v_unlock := public.next_gpsl_season_label(v_season_id);

  UPDATE public."Clubs" c
  SET new_owner_releases_remaining = new_owner_releases_remaining - 1
  WHERE c."ShortName" = v_club
  RETURNING c.new_owner_releases_remaining INTO v_remaining;

  v_ledger_id := public.post_club_ledger(
    v_club,
    'new_owner_release',
    abs(v_fee),
    format('New Owner release refund: %s (purchase fee)', v_player."Name"),
    jsonb_build_object(
      'player_id', v_pid,
      'player_name', v_player."Name",
      'purchase_fee', v_fee,
      'new_owner_release', true,
      'refund', true
    ),
    v_season_id,
    NULL,
    true,
    true
  );

  PERFORM public.ensure_foreign_buyer_club();

  INSERT INTO public."Transfer_History" (
    player_id,
    seller_club_id,
    buyer_club_id,
    fee,
    agent_fee,
    transfer_time,
    listing_id,
    foreign_buyer_name,
    transfer_sale_note
  )
  VALUES (
    v_player."Konami_ID",
    v_club,
    'FOREIGN',
    0,
    0,
    now(),
    NULL,
    format('New Owner release (₿ %s Central Bank refund)', to_char(v_fee, 'FM999999999999')),
    'new_owner_release'
  );

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'player_name', v_player."Name",
    'fee', v_fee,
    'refund', v_fee,
    'new_balance', v_balance + abs(v_fee),
    'new_owner_releases_remaining', v_remaining,
    'new_owner_slots_remaining', v_remaining,
    'unavailable_until_season', v_unlock,
    'ledger_id', v_ledger_id
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- Manager sack — pre-season or January window (same as New Owner actions)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.manager_sack_window_open()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.club_new_owner_release_window_open();
$$;

CREATE OR REPLACE FUNCTION public.manager_sack()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text;
  v_mgr public."Managers"%rowtype;
  v_payout numeric;
  v_sacks smallint;
  v_season_id bigint;
  v_result jsonb;
  v_month text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT public.manager_sack_window_open() THEN
    RAISE EXCEPTION
      'Manager sack is only available in the pre-season window or the January transfer window';
  END IF;

  v_club := public.my_club_shortname();
  IF v_club IS NULL THEN
    RAISE EXCEPTION 'No club linked to your account';
  END IF;

  SELECT manager_sacks_remaining INTO v_sacks
  FROM public."Clubs"
  WHERE "ShortName" = v_club
  FOR UPDATE;

  IF coalesce(v_sacks, 0) < 1 THEN
    RAISE EXCEPTION 'Manager sack already used this season';
  END IF;

  SELECT * INTO v_mgr
  FROM public."Managers"
  WHERE contracted_club = v_club
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No manager signed at your club';
  END IF;

  v_payout := round(greatest(v_mgr.market_value, 0)::numeric / 2.0, 0);

  UPDATE public."Clubs"
  SET manager_sacks_remaining = 0
  WHERE "ShortName" = v_club;

  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  v_month := lower(coalesce(public.competition_active_gpsl_month(v_season_id, now()), ''));

  v_result := public.manager_release_from_club(
    v_mgr.id,
    v_club,
    v_payout,
    'contract_release_comp',
    format('Manager sack — %s (half MV)', v_mgr.name),
    jsonb_build_object(
      'manager_sack', true,
      'gpsl_month', nullif(v_month, '')
    )
  );

  PERFORM public.manager_club_sack_block_record(v_club, v_mgr.id, v_season_id);

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_new_owner_slot_consume(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_new_owner_slot_restore(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.new_owner_listing_settle_slot(bigint, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_new_owner_list_preview(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.player_new_owner_transfer_list(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_sack_window_open() TO authenticated;

-- ---------------------------------------------------------------------------
-- Same-season override — New Owner transfer list only
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.assert_player_new_owner_listable(p_player_id text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_seasons smallint;
  v_legacy boolean;
BEGIN
  SELECT p.contract_seasons_remaining, p.pesdb_unavailable
  INTO v_seasons, v_legacy
  FROM public."Players" p
  WHERE p."Konami_ID"::text = btrim(p_player_id);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF coalesce(v_legacy, false) THEN
    RAISE EXCEPTION
      'This player card is no longer on pesdb.net (legacy card). It cannot be sold or listed. Renew for one season at a time from your squad.';
  END IF;

  IF v_seasons IS NOT NULL AND v_seasons <= 1 THEN
    RAISE EXCEPTION
      'Player is in the final year of their contract and cannot be sold or listed. Renew or expire the contract from your squad page.';
  END IF;

  -- Same-season signing lock intentionally not applied for New Owner listings.
END;
$function$;

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

  IF coalesce(NEW.new_owner_slot, false) THEN
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

CREATE OR REPLACE FUNCTION public.trg_transfer_bid_block_same_season_player()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_player_id text;
  v_new_owner_listing boolean := false;
BEGIN
  v_player_id := btrim(coalesce(NEW.player_id::text, NEW.direct_bid_id::text, ''));

  IF v_player_id = '' AND NEW.listing_id IS NOT NULL THEN
    SELECT btrim(l.player_id::text), coalesce(l.new_owner_slot, false)
    INTO v_player_id, v_new_owner_listing
    FROM public."Player_Transfer_Listings" l
    WHERE l.id = NEW.listing_id;
  ELSIF NEW.listing_id IS NOT NULL THEN
    SELECT coalesce(l.new_owner_slot, false)
    INTO v_new_owner_listing
    FROM public."Player_Transfer_Listings" l
    WHERE l.id = NEW.listing_id;
  END IF;

  IF v_player_id IS NULL OR v_player_id = '' THEN
    RETURN NEW;
  END IF;

  IF v_new_owner_listing THEN
    RETURN NEW;
  END IF;

  PERFORM public.assert_player_transferable(v_player_id);
  RETURN NEW;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.assert_player_new_owner_listable(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
