-- Run transfer engine once (standard 7pm listings + draft settlement when due).
-- SQL Editor: SELECT transferengine_run_report();
-- Site admin UI: admin_transferengine_run() (authenticated admins only).

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
  v_blocked boolean;
  v_finish_passed boolean;
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

  RETURN jsonb_build_object(
    'ok', true,
    'note', 'transferengine_run() returns void — blank in SQL Editor is normal',
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
    )
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

GRANT EXECUTE ON FUNCTION public.transferengine_run_report() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_transferengine_run() TO authenticated;
