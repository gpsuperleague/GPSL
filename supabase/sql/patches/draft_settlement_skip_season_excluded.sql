-- =============================================================================
-- Draft / transfer settlement — NEVER abort the whole engine on season exclusion
--
-- Symptom (Admin → Run transfer engine):
--   "This player is excluded from GPSL for the current season (admin season exclusion)."
--
-- Cause: assert_player_available_for_signing / player_assign_to_club RAISE
-- aborts transferengine_run() so NO draft winners settle.
--
-- This patch:
--   1) Soft-skips excluded players in accept_draft_sale (close, no sign)
--   2) Wraps standard + draft settle loops so one failure cannot abort the tick
--   3) Makes transferengine_run / report swallow exclusion errors (JSON, not RPC 400)
--
-- Run ENTIRE file in Supabase SQL Editor, then Admin → Run transfer engine.
--
-- See who is blocked:
--   SELECT l.id, l.listing_type, l.player_id, p."Name", l.status,
--          l.current_highest_bidder, l.current_highest_bid
--   FROM public."Player_Transfer_Listings" l
--   LEFT JOIN public."Players" p ON p."Konami_ID"::text = btrim(l.player_id::text)
--   WHERE l.status = 'Active'
--     AND public.gpdb_player_is_season_excluded(btrim(l.player_id::text));
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Helper: close a listing without completing (excluded / skipped)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.transferengine_close_listing_incomplete(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  UPDATE public."Player_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = false
  WHERE id = p_listing_id
    AND status IN ('Active', 'Review');
END;
$function$;

CREATE OR REPLACE FUNCTION public.transferengine_is_exclusion_error(p_msg text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(p_msg, '') ILIKE '%excluded from GPSL%'
      OR coalesce(p_msg, '') ILIKE '%season exclusion%';
$$;

-- ---------------------------------------------------------------------------
-- Player draft accept — soft-skip season exclusions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.transferengine_accept_draft_sale(p_listing_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Player_Transfer_Listings"%rowtype;
  v_amount  numeric;
  v_buyer   text;
  v_player  public."Players"%rowtype;
  v_history_id bigint;
  v_draft_start timestamptz;
  v_pid     text;
BEGIN
  SELECT draft_auction_start_time INTO v_draft_start
  FROM public.global_settings WHERE id = 1;

  SELECT *
  INTO v_listing
  FROM public."Player_Transfer_Listings"
  WHERE id = p_listing_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_listing.listing_type IS DISTINCT FROM 'draft' THEN
    RETURN;
  END IF;

  IF v_listing.status NOT IN ('Active', 'Review') THEN
    RETURN;
  END IF;

  IF to_regprocedure('public.transferengine_normalize_club_short_name(text)') IS NOT NULL THEN
    v_buyer := public.transferengine_normalize_club_short_name(
      v_listing.current_highest_bidder::text
    );
  ELSE
    v_buyer := nullif(btrim(v_listing.current_highest_bidder::text), '');
  END IF;
  v_amount := v_listing.current_highest_bid;

  IF v_buyer IS NULL OR v_amount IS NULL OR v_amount <= 0 THEN
    SELECT b.bid_amount, b.bidder_club_id
    INTO v_amount, v_buyer
    FROM public."Player_Transfer_Bids" b
    WHERE b.is_direct = true
      AND b.listing_id = v_listing.id
      AND (v_draft_start IS NULL OR b.bid_time >= v_draft_start)
    ORDER BY b.bid_amount DESC, b.bid_time ASC
    LIMIT 1;

    IF to_regprocedure('public.transferengine_normalize_club_short_name(text)') IS NOT NULL THEN
      v_buyer := public.transferengine_normalize_club_short_name(v_buyer);
    ELSE
      v_buyer := nullif(btrim(v_buyer), '');
    END IF;
  END IF;

  IF v_buyer IS NULL OR v_amount IS NULL OR v_amount <= 0 THEN
    PERFORM public.transferengine_close_listing_incomplete(v_listing.id);
    RETURN;
  END IF;

  UPDATE public."Player_Transfer_Listings"
  SET current_highest_bid = v_amount,
      current_highest_bidder = v_buyer
  WHERE id = v_listing.id;

  v_pid := btrim(v_listing.player_id::text);

  SELECT *
  INTO v_player
  FROM public."Players"
  WHERE "Konami_ID"::text = v_pid
  FOR UPDATE;

  IF NOT FOUND THEN
    PERFORM public.transferengine_close_listing_incomplete(v_listing.id);
    RETURN;
  END IF;

  IF v_player."Contracted_Team" IS NOT NULL
     AND btrim(v_player."Contracted_Team"::text) <> '' THEN
    UPDATE public."Player_Transfer_Listings"
    SET status = 'Closed',
        transfer_completed = (btrim(v_player."Contracted_Team"::text) = v_buyer),
        winning_bid = CASE WHEN btrim(v_player."Contracted_Team"::text) = v_buyer THEN v_amount ELSE winning_bid END,
        winning_club = CASE WHEN btrim(v_player."Contracted_Team"::text) = v_buyer THEN v_buyer ELSE winning_club END
    WHERE id = v_listing.id;
    RETURN;
  END IF;

  -- Soft-skip: season exclusion must NOT abort the engine
  IF public.gpdb_player_is_season_excluded(v_pid) THEN
    PERFORM public.transferengine_close_listing_incomplete(v_listing.id);
    RAISE NOTICE
      'Draft listing % skipped — player % (%) is season-excluded',
      p_listing_id, v_pid, coalesce(v_player."Name", '?');
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public."Club_Finances" f WHERE f.club_name = v_buyer
  ) THEN
    RAISE EXCEPTION 'Club_Finances missing for buyer % (listing %)', v_buyer, p_listing_id;
  END IF;

  BEGIN
    IF to_regprocedure('public.player_assign_to_club(text, text, numeric, boolean)') IS NOT NULL THEN
      PERFORM public.player_assign_to_club(v_pid, v_buyer, NULL::numeric, false);
    ELSIF to_regprocedure('public.player_assign_to_club(text, text, numeric)') IS NOT NULL THEN
      PERFORM public.player_assign_to_club(v_pid, v_buyer, NULL::numeric);
    ELSE
      PERFORM public.player_assign_to_club(v_pid, v_buyer);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    IF public.transferengine_is_exclusion_error(SQLERRM) THEN
      PERFORM public.transferengine_close_listing_incomplete(v_listing.id);
      RAISE NOTICE 'Draft listing % skipped after assign guard: %', p_listing_id, SQLERRM;
      RETURN;
    END IF;
    RAISE;
  END;

  INSERT INTO public."Transfer_History" (
    player_id,
    seller_club_id,
    buyer_club_id,
    fee,
    agent_fee,
    transfer_time,
    listing_id
  )
  VALUES (
    v_pid,
    NULL,
    v_buyer,
    v_amount,
    0,
    now(),
    v_listing.id
  )
  RETURNING id INTO v_history_id;

  IF to_regprocedure('public.post_transfer_ledger_for_history(bigint)') IS NOT NULL THEN
    PERFORM public.post_transfer_ledger_for_history(v_history_id);
  END IF;

  UPDATE public."Player_Transfer_Listings"
  SET status = 'Closed',
      transfer_completed = true,
      winning_bid = v_amount,
      winning_club = v_buyer
  WHERE id = v_listing.id;
END;
$function$;

-- (Standard accept_sale left unchanged — process_standard_listings catches
--  exclusion errors per listing and closes incomplete.)

-- ---------------------------------------------------------------------------
-- Batch draft settle with per-listing catch
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.transferengine_settle_player_draft_listings(
  p_batch_limit int DEFAULT 200
)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing public."Player_Transfer_Listings"%rowtype;
  v_settled int := 0;
  v_skipped int := 0;
  v_limit int := greatest(coalesce(p_batch_limit, 200), 1);
BEGIN
  FOR v_listing IN
    SELECT *
    FROM public."Player_Transfer_Listings"
    WHERE listing_type = 'draft'
      AND status = 'Active'
    ORDER BY id
    LIMIT v_limit
  LOOP
    BEGIN
      PERFORM public.transferengine_accept_draft_sale(v_listing.id);
      IF EXISTS (
        SELECT 1 FROM public."Player_Transfer_Listings" l
        WHERE l.id = v_listing.id AND l.status = 'Closed' AND l.transfer_completed = true
      ) THEN
        v_settled := v_settled + 1;
      ELSIF EXISTS (
        SELECT 1 FROM public."Player_Transfer_Listings" l
        WHERE l.id = v_listing.id AND l.status = 'Closed' AND coalesce(l.transfer_completed, false) = false
      ) THEN
        v_skipped := v_skipped + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      IF public.transferengine_is_exclusion_error(SQLERRM) THEN
        PERFORM public.transferengine_close_listing_incomplete(v_listing.id);
        v_skipped := v_skipped + 1;
        RAISE WARNING 'Draft listing % closed (season exclusion): %', v_listing.id, SQLERRM;
      ELSE
        RAISE WARNING 'Draft listing % failed: %', v_listing.id, SQLERRM;
      END IF;
    END;
  END LOOP;

  RAISE NOTICE 'Player draft settle batch: settled=%, skipped/incomplete=%', v_settled, v_skipped;
  RETURN v_settled;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Standard listings loop — catch per listing
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.transferengine_process_standard_listings(
  p_now timestamptz DEFAULT now()
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_listing record;
  v_pass int := 0;
BEGIN
  LOOP
    v_pass := v_pass + 1;
    EXIT WHEN v_pass > 24;

    IF to_regprocedure('public.transferengine_sync_listing_high_bid(bigint)') IS NOT NULL THEN
      FOR v_listing IN
        SELECT l.id
        FROM public."Player_Transfer_Listings" l
        WHERE l.status = 'Active'
          AND l.listing_type IS DISTINCT FROM 'draft'
          AND p_now >= l.end_time
      LOOP
        BEGIN
          PERFORM public.transferengine_sync_listing_high_bid(v_listing.id);
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'sync_listing_high_bid % failed: %', v_listing.id, SQLERRM;
        END;
      END LOOP;
    END IF;

    FOR v_listing IN
      SELECT l.id
      FROM public."Player_Transfer_Listings" l
      WHERE l.status = 'Active'
        AND l.listing_type IS DISTINCT FROM 'draft'
        AND p_now >= l.end_time
      ORDER BY l.id
    LOOP
      BEGIN
        IF to_regprocedure('public.transferengine_handle_expiry_or_extension(bigint)') IS NOT NULL THEN
          PERFORM public.transferengine_handle_expiry_or_extension(v_listing.id);
        ELSE
          PERFORM public.transferengine_accept_sale(v_listing.id);
        END IF;
      EXCEPTION WHEN OTHERS THEN
        IF public.transferengine_is_exclusion_error(SQLERRM) THEN
          PERFORM public.transferengine_close_listing_incomplete(v_listing.id);
          RAISE WARNING 'Standard listing % closed (season exclusion): %', v_listing.id, SQLERRM;
        ELSE
          RAISE WARNING 'Standard listing % failed: %', v_listing.id, SQLERRM;
        END IF;
      END;
    END LOOP;

    EXIT WHEN NOT EXISTS (
      SELECT 1
      FROM public."Player_Transfer_Listings" l
      WHERE l.status = 'Active'
        AND l.listing_type IS DISTINCT FROM 'draft'
        AND p_now >= l.end_time
    );
  END LOOP;
END;
$function$;

-- ---------------------------------------------------------------------------
-- settle_draft_auctions — always use batched/safe player settle
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.transferengine_settle_draft_auctions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_settings record;
  v_now timestamptz := now();
  v_player_draft_active int;
  v_should_settle_players boolean;
BEGIN
  SELECT
    draft_auction_enabled,
    manager_draft_auction_enabled,
    club_auction_enabled,
    draft_random_finish_time
  INTO v_settings
  FROM public.global_settings
  WHERE id = 1;

  IF v_settings.draft_random_finish_time IS NULL
     OR v_now < v_settings.draft_random_finish_time THEN
    RETURN;
  END IF;

  SELECT count(*)::int INTO v_player_draft_active
  FROM public."Player_Transfer_Listings"
  WHERE listing_type = 'draft' AND status = 'Active';

  PERFORM public.transferengine_process_standard_listings(v_now);

  v_should_settle_players :=
    v_player_draft_active > 0
    AND NOT public.transferengine_standard_listings_block_draft_settlement(
      v_now,
      v_settings.draft_random_finish_time
    );

  IF v_should_settle_players THEN
    -- Multiple passes in case batch limit < backlog
    PERFORM public.transferengine_settle_player_draft_listings(200);
    PERFORM public.transferengine_settle_player_draft_listings(200);
    PERFORM public.transferengine_settle_player_draft_listings(200);
  END IF;

  IF to_regprocedure('public.transferengine_settle_manager_draft_auctions_only()') IS NOT NULL THEN
    BEGIN
      PERFORM public.transferengine_settle_manager_draft_auctions_only();
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'manager draft settle failed: %', SQLERRM;
    END;
  END IF;

  IF to_regprocedure('public.transferengine_settle_club_auctions_only()') IS NOT NULL THEN
    BEGIN
      PERFORM public.transferengine_settle_club_auctions_only();
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'club auction settle failed: %', SQLERRM;
    END;
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- transferengine_run — never surface season-exclusion as a hard RPC failure
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.transferengine_run()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  BEGIN
    PERFORM set_config('gpsl.defer_squad_overflow', 'on', true);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  BEGIN
    PERFORM public.transferengine_process_standard_listings(now());
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'process_standard_listings failed: %', SQLERRM;
  END;

  BEGIN
    PERFORM public.transferengine_settle_draft_auctions();
  EXCEPTION WHEN OTHERS THEN
    IF public.transferengine_is_exclusion_error(SQLERRM) THEN
      RAISE WARNING 'settle_draft_auctions hit exclusion (should be soft-skipped): %', SQLERRM;
    ELSE
      RAISE WARNING 'settle_draft_auctions failed: %', SQLERRM;
    END IF;
  END;

  IF to_regprocedure('public.transferengine_finalize_deferred_squad_overflow()') IS NOT NULL THEN
    BEGIN
      PERFORM public.transferengine_finalize_deferred_squad_overflow();
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'finalize_deferred_squad_overflow failed: %', SQLERRM;
    END;
  END IF;

  BEGIN
    PERFORM set_config('gpsl.defer_squad_overflow', '', true);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Report — return JSON error instead of throwing to the admin UI
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.transferengine_run_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_settings record;
  v_stuck int;
  v_draft_before int;
  v_draft_after int;
  v_mgr_draft_before int := 0;
  v_mgr_draft_after int := 0;
  v_blocked boolean := false;
  v_finish_passed boolean;
  v_excluded_active int := 0;
  v_err text;
BEGIN
  SELECT
    draft_auction_enabled,
    manager_draft_auction_enabled,
    draft_random_finish_time
  INTO v_settings
  FROM global_settings
  WHERE id = 1;

  v_finish_passed :=
    v_settings.draft_random_finish_time IS NOT NULL
    AND now() >= v_settings.draft_random_finish_time;

  BEGIN
    v_blocked := public.transferengine_standard_listings_block_draft_settlement(
      now(),
      v_settings.draft_random_finish_time
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := false;
  END;

  SELECT count(*)::int INTO v_stuck
  FROM "Player_Transfer_Listings" l
  WHERE l.status = 'Active'
    AND l.listing_type IS DISTINCT FROM 'draft'
    AND l.end_time <= now();

  SELECT count(*)::int INTO v_draft_before
  FROM "Player_Transfer_Listings" l
  WHERE l.listing_type = 'draft' AND l.status = 'Active';

  BEGIN
    SELECT count(*)::int INTO v_mgr_draft_before
    FROM public."Manager_Transfer_Listings" l
    WHERE l.listing_type = 'draft' AND l.status = 'Active';
  EXCEPTION WHEN OTHERS THEN
    v_mgr_draft_before := 0;
  END;

  SELECT count(*)::int INTO v_excluded_active
  FROM public."Player_Transfer_Listings" l
  WHERE l.status = 'Active'
    AND public.gpdb_player_is_season_excluded(btrim(l.player_id::text));

  BEGIN
    PERFORM public.transferengine_run();
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;

  SELECT count(*)::int INTO v_draft_after
  FROM "Player_Transfer_Listings" l
  WHERE l.listing_type = 'draft' AND l.status = 'Active';

  BEGIN
    SELECT count(*)::int INTO v_mgr_draft_after
    FROM public."Manager_Transfer_Listings" l
    WHERE l.listing_type = 'draft' AND l.status = 'Active';
  EXCEPTION WHEN OTHERS THEN
    v_mgr_draft_after := 0;
  END;

  RETURN jsonb_build_object(
    'ok', v_err IS NULL,
    'error', v_err,
    'note', CASE
      WHEN v_err IS NOT NULL THEN v_err
      ELSE 'transferengine_run() returns void — blank in SQL Editor is normal'
    END,
    'ran_at', now(),
    'draft_auction_enabled', COALESCE(v_settings.draft_auction_enabled, false),
    'manager_draft_auction_enabled', COALESCE(v_settings.manager_draft_auction_enabled, false),
    'draft_random_finish_time', v_settings.draft_random_finish_time,
    'secret_finish_passed', v_finish_passed,
    'blocked_by_7pm_transfer_list', v_blocked,
    'stuck_standard_before', v_stuck,
    'active_draft_before', v_draft_before,
    'active_draft_after', v_draft_after,
    'draft_settled_count', v_draft_before - v_draft_after,
    'active_manager_draft_before', v_mgr_draft_before,
    'active_manager_draft_after', v_mgr_draft_after,
    'manager_draft_settled_count', v_mgr_draft_before - v_mgr_draft_after,
    'active_excluded_listings_before', v_excluded_active
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_transferengine_run()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN public.transferengine_run_report();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.transferengine_close_listing_incomplete(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_close_listing_incomplete(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.transferengine_accept_draft_sale(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_accept_draft_sale(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.transferengine_settle_player_draft_listings(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_settle_player_draft_listings(int) TO service_role;
GRANT EXECUTE ON FUNCTION public.transferengine_run() TO authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_run() TO service_role;
GRANT EXECUTE ON FUNCTION public.transferengine_run_report() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_transferengine_run() TO authenticated;
