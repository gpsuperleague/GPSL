-- =============================================================================
-- Club auction — auto-settle via transfer engine (same cron as player/manager draft)
-- Run once in Supabase SQL Editor after club_auction.sql.
--
-- Flow: GitHub Actions (every minute) → Edge Function transferengine_run
--       → transferengine_run_report() → transferengine_run()
--       → transferengine_settle_draft_auctions()
--       → transferengine_settle_club_auctions_only()  (after draft_random_finish_time)
-- =============================================================================

-- Settle active club listings after secret finish even if admin toggled club auction off.
CREATE OR REPLACE FUNCTION public.transferengine_settle_club_auctions_only()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_finish timestamptz;
  v_listing public."Club_Auction_Listings"%rowtype;
BEGIN
  SELECT draft_random_finish_time
  INTO v_finish
  FROM public.global_settings
  WHERE id = 1;

  IF v_finish IS NULL OR now() < v_finish THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public."Club_Auction_Listings"
    WHERE status = 'Active'
  ) THEN
    RETURN;
  END IF;

  FOR v_listing IN
    SELECT *
    FROM public."Club_Auction_Listings"
    WHERE status = 'Active'
    ORDER BY id
  LOOP
    PERFORM public.transferengine_accept_club_auction_sale(v_listing.id);
  END LOOP;
END;
$function$;

-- Still run settlement tick when only club auction listings remain active.
CREATE OR REPLACE FUNCTION public.transferengine_settle_draft_auctions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_settings record;
  v_listing  public."Player_Transfer_Listings"%rowtype;
  v_now      timestamptz := now();
  v_club_active int;
BEGIN
  SELECT
    draft_auction_enabled,
    manager_draft_auction_enabled,
    club_auction_enabled,
    draft_random_finish_time
  INTO v_settings
  FROM public.global_settings
  WHERE id = 1;

  SELECT count(*)::int
  INTO v_club_active
  FROM public."Club_Auction_Listings"
  WHERE status = 'Active';

  IF NOT COALESCE(v_settings.draft_auction_enabled, false)
     AND NOT COALESCE(v_settings.manager_draft_auction_enabled, false)
     AND NOT COALESCE(v_settings.club_auction_enabled, false) THEN
    IF NOT (
      v_club_active > 0
      AND v_settings.draft_random_finish_time IS NOT NULL
      AND v_now >= v_settings.draft_random_finish_time
    ) THEN
      RETURN;
    END IF;
  END IF;

  IF v_settings.draft_random_finish_time IS NULL THEN
    RETURN;
  END IF;

  IF v_now < v_settings.draft_random_finish_time THEN
    RETURN;
  END IF;

  PERFORM public.transferengine_process_standard_listings(v_now);

  IF COALESCE(v_settings.draft_auction_enabled, false)
     AND NOT public.transferengine_standard_listings_block_draft_settlement(
       v_now,
       v_settings.draft_random_finish_time
     ) THEN
    FOR v_listing IN
      SELECT *
      FROM public."Player_Transfer_Listings"
      WHERE listing_type = 'draft' AND status = 'Active'
    LOOP
      PERFORM public.transferengine_accept_draft_sale(v_listing.id);
    END LOOP;
  END IF;

  PERFORM public.transferengine_settle_manager_draft_auctions_only();
  PERFORM public.transferengine_settle_club_auctions_only();
END;
$function$;

-- Transfer engine report — include club auction counts (visible in admin + Edge Function logs)
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
  v_mgr_draft_before int;
  v_mgr_draft_after int;
  v_club_before int;
  v_club_after int;
  v_blocked boolean;
  v_finish_passed boolean;
BEGIN
  SELECT
    draft_auction_enabled,
    manager_draft_auction_enabled,
    club_auction_enabled,
    draft_random_finish_time
  INTO v_settings
  FROM global_settings
  WHERE id = 1;

  v_finish_passed :=
    v_settings.draft_random_finish_time IS NOT NULL
    AND now() >= v_settings.draft_random_finish_time;

  v_blocked := public.transferengine_standard_listings_block_draft_settlement(
    now(),
    v_settings.draft_random_finish_time
  );

  SELECT count(*)::int
  INTO v_stuck
  FROM "Player_Transfer_Listings" l
  WHERE l.status = 'Active'
    AND l.listing_type IS DISTINCT FROM 'draft'
    AND l.end_time <= now();

  SELECT count(*)::int
  INTO v_draft_before
  FROM "Player_Transfer_Listings" l
  WHERE l.listing_type = 'draft'
    AND l.status = 'Active';

  SELECT count(*)::int
  INTO v_mgr_draft_before
  FROM public."Manager_Transfer_Listings" l
  WHERE l.listing_type = 'draft'
    AND l.status = 'Active';

  SELECT count(*)::int
  INTO v_club_before
  FROM public."Club_Auction_Listings" l
  WHERE l.status = 'Active';

  PERFORM public.transferengine_run();

  SELECT count(*)::int
  INTO v_draft_after
  FROM "Player_Transfer_Listings" l
  WHERE l.listing_type = 'draft'
    AND l.status = 'Active';

  SELECT count(*)::int
  INTO v_mgr_draft_after
  FROM public."Manager_Transfer_Listings" l
  WHERE l.listing_type = 'draft'
    AND l.status = 'Active';

  SELECT count(*)::int
  INTO v_club_after
  FROM public."Club_Auction_Listings" l
  WHERE l.status = 'Active';

  RETURN jsonb_build_object(
    'ok', true,
    'note', 'transferengine_run() returns void — blank in SQL Editor is normal',
    'ran_at', now(),
    'draft_auction_enabled', COALESCE(v_settings.draft_auction_enabled, false),
    'manager_draft_auction_enabled', COALESCE(v_settings.manager_draft_auction_enabled, false),
    'club_auction_enabled', COALESCE(v_settings.club_auction_enabled, false),
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
    'active_club_auction_before', v_club_before,
    'active_club_auction_after', v_club_after,
    'club_auction_settled_count', v_club_before - v_club_after,
    'draft_by_status', (
      SELECT coalesce(jsonb_object_agg(status, cnt), '{}'::jsonb)
      FROM (
        SELECT l.status, count(*)::int AS cnt
        FROM "Player_Transfer_Listings" l
        WHERE l.listing_type = 'draft'
        GROUP BY l.status
      ) s
    ),
    'manager_draft_by_status', (
      SELECT coalesce(jsonb_object_agg(status, cnt), '{}'::jsonb)
      FROM (
        SELECT l.status, count(*)::int AS cnt
        FROM public."Manager_Transfer_Listings" l
        WHERE l.listing_type = 'draft'
        GROUP BY l.status
      ) s
    ),
    'club_auction_still_active', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
        'listing_id', l.id,
        'club_short_name', l.club_short_name,
        'high_bid', l.current_highest_bid,
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
