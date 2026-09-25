-- =============================================================================
-- Hotfix: Close Finances fails on underperformance perpetual listing
--
-- Error:
--   This player requested a transfer after club underperformance — the listing
--   relists automatically and cannot be removed manually.
--
-- Cause:
--   competition_admin_close_finances → competition_post_eos_ffp_charges
--   → club_release_player_ffp_eos closes open listings with
--   transfer_completed = false. Trigger trg_block_perpetual_listing_close
--   blocks that for perpetual_renew (underperformance) listings — intended for
--   manual owner cancel, not system FFP / foreign release.
--
-- Fix:
--   1) FFP release closes listings as completed sales and clears perpetual_renew
--   2) Trigger allows system closes via session GUC (belt-and-suspenders)
--   3) Orphan perpetual relist (player left club) closes the same way
--
-- Safe re-run. After apply, retry Close Finances.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Trigger: still block manual cancel; allow system GUC bypass
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_block_perpetual_listing_close()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  -- System release / FFP / foreign sale may set this for the transaction
  IF lower(coalesce(current_setting('gpsl.allow_perpetual_listing_close', true), ''))
       IN ('1', 'on', 'true', 'yes') THEN
    RETURN NEW;
  END IF;

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

-- ---------------------------------------------------------------------------
-- 2) FFP EOS release: close listings as completed + clear perpetual flag
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.club_release_player_ffp_eos(
  p_club_short_name text,
  p_player_id text,
  p_season_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_club text := btrim(p_club_short_name);
  v_pid text := btrim(p_player_id);
  v_player public."Players"%rowtype;
  v_fee numeric;
  v_bal numeric;
  v_history_id bigint;
BEGIN
  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  IF public.player_contracted_club_key(v_player."Contracted_Team") IS DISTINCT FROM v_club THEN
    RAISE EXCEPTION 'Player is not at club %', v_club;
  END IF;

  v_fee := greatest(coalesce(v_player.market_value::numeric, 0), 0);
  IF v_fee <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'zero_mv', 'player_id', v_pid);
  END IF;

  -- Allow + mark completed so underperformance perpetual listings can close
  PERFORM set_config('gpsl.allow_perpetual_listing_close', '1', true);

  UPDATE public."Player_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = true,
      perpetual_renew = false,
      winning_bid = null,
      winning_club = null
  WHERE l.player_id::text = v_pid
    AND l.seller_club_id = v_club
    AND l.status IN ('Active', 'Review', 'Seller Review');

  UPDATE public."Player_Transfer_Bids" b
  SET status = 'rejected'
  WHERE b.is_direct = true
    AND b.listing_id IS NULL
    AND lower(coalesce(b.status::text, '')) = 'active'
    AND (
      (b.player_id IS NOT NULL AND btrim(b.player_id::text) = v_pid)
      OR (b.direct_bid_id IS NOT NULL AND btrim(b.direct_bid_id::text) = v_pid)
    );

  SELECT balance INTO v_bal
  FROM public."Club_Finances"
  WHERE club_name = v_club
  FOR UPDATE;

  IF v_bal IS NULL THEN
    RAISE EXCEPTION 'Club finances not found for %', v_club;
  END IF;

  PERFORM public.ensure_foreign_buyer_club();
  PERFORM public.player_release_from_club(v_pid);
  PERFORM public.player_club_rejoin_block_record(v_pid, v_club, p_season_id, 'ffp_eos_release');

  UPDATE public."Club_Finances"
  SET balance = v_bal + v_fee
  WHERE club_name = v_club;

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
    v_fee,
    0,
    now(),
    NULL,
    'FFP release (market value)',
    'ffp_eos_release'
  )
  RETURNING id INTO v_history_id;

  PERFORM public.post_club_ledger(
    v_club,
    'transfer_foreign_sale',
    v_fee,
    format('FFP release: %s', coalesce(v_player."Name", v_pid)),
    jsonb_build_object(
      'transfer_history_id', v_history_id,
      'player_id', v_pid,
      'transfer_sale_note', 'ffp_eos_release',
      'season_id', p_season_id
    ),
    p_season_id,
    NULL,
    false,
    false
  );

  RETURN jsonb_build_object(
    'ok', true,
    'player_id', v_pid,
    'player_name', v_player."Name",
    'rating', v_player."Rating",
    'fee', v_fee,
    'balance_after', v_bal + v_fee,
    'history_id', v_history_id
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_release_player_ffp_eos(text, text, bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3) Perpetual relist: if player already left club, close cleanly
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
    PERFORM set_config('gpsl.allow_perpetual_listing_close', '1', true);
    UPDATE public."Player_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = true,
        perpetual_renew = false
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

NOTIFY pgrst, 'reload schema';

COMMIT;
