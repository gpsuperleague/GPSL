-- =============================================================================
-- Manager FA board: re-wire into transferengine cron + keepalive
--
-- Bug: later transferengine_run_report() patches dropped
--   manager_window_fa_month_tick(), so June/July/August/January no longer
--   auto-spawn / top up the board of 10 free-agent managers.
--
-- This patch:
--   • month_tick: process → spawn → ensure (refill sold slots same run)
--   • transferengine_run_report() calls month_tick again (with calendar tick)
--   • manager_window_fa_keepalive() for Manager Market page self-heal
--   • One-shot restock to 10 on apply
--
-- After apply:
--   SELECT public.admin_manager_window_fa_diagnose();
--   -- or open Manager Market / Admin → Top up FA board to 10
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.manager_window_fa_month_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_process jsonb;
  v_spawn jsonb;
  v_topup jsonb;
BEGIN
  -- Settle / renew expired FA rows first so sold slots free up this tick
  v_process := public.manager_process_window_fa_listings();
  -- Fresh board when a TW month starts (idempotent per month)
  v_spawn := public.manager_window_fa_spawn(NULL, NULL, false);
  -- Always top up to 10 live (end_time > now) listings
  v_topup := public.manager_window_fa_ensure_board(NULL, NULL, 10);

  RETURN jsonb_build_object(
    'ok', true,
    'process', v_process,
    'spawn', v_spawn,
    'ensure_board', v_topup
  );
END;
$function$;

COMMENT ON FUNCTION public.manager_window_fa_month_tick() IS
  'Cron tick: renew/settle window_fa, spawn month board, top up to 10.';

-- Soft keep-alive for Manager Market (authenticated). Never force-closes bids.
CREATE OR REPLACE FUNCTION public.manager_window_fa_keepalive()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_tick jsonb;
BEGIN
  IF auth.uid() IS NULL
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Sign in required';
  END IF;

  v_tick := public.manager_window_fa_month_tick();
  RETURN jsonb_build_object('ok', true, 'tick', v_tick);
END;
$function$;

COMMENT ON FUNCTION public.manager_window_fa_keepalive() IS
  'Owner/admin keep-alive: run FA month tick (spawn + top up to 10) without force refresh.';

-- Re-attach FA board to the transfer-engine cron report (plus calendar tick).
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
  v_calendar jsonb;
  v_mgr_fa jsonb;
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

  IF to_regprocedure('public.competition_calendar_month_tick()') IS NOT NULL THEN
    v_calendar := public.competition_calendar_month_tick();
  ELSE
    v_calendar := jsonb_build_object('skipped', true);
  END IF;

  BEGIN
    v_mgr_fa := public.manager_window_fa_month_tick();
  EXCEPTION WHEN OTHERS THEN
    v_mgr_fa := jsonb_build_object('ok', false, 'error', SQLERRM);
  END;

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
    'calendar_month_tick', v_calendar,
    'manager_window_fa', v_mgr_fa,
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

GRANT EXECUTE ON FUNCTION public.manager_window_fa_month_tick() TO service_role;
GRANT EXECUTE ON FUNCTION public.manager_window_fa_keepalive() TO authenticated;
GRANT EXECUTE ON FUNCTION public.manager_window_fa_keepalive() TO service_role;
GRANT EXECUTE ON FUNCTION public.transferengine_run_report() TO service_role;
GRANT EXECUTE ON FUNCTION public.transferengine_run_report() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Fill July (or current TW month) immediately when this patch is applied as postgres
SELECT public.admin_manager_window_fa_restock(true, 10) AS manager_fa_restock_result;
