-- =============================================================================
-- Vanilla league reset: fill day-zero gaps
--
-- Adds admin_test_reset_clear_day_zero_extras() and hooks it into
-- admin_test_reset_execute (before Phase G).
--
-- WIPE (were missing):
--   stadium Capacity → base_capacity + fill columns
--   club scouting boards (owner scouting KEPT — follows owner by design)
--   contract_expiry_wage_bids
--   club_squad_player_designations
--   international_nation_managers
--   gpsl_discord_feed_queue (+ notification / who's-who state)
--   gpsl_transfer_ticker_cycle
--   gpsl_staff_alerts (+ reads) if present
--
-- KEEP unchanged: GPDB, auth, Clubs rows, Managers catalog, nations,
--   waiting list, prize inventory, owner scouting, config templates.
-- Admin checklist is season-scoped (CASCADE with seasons — expected).
--
-- Safe re-run. Prefer after admin_prelaunch_test_reset.sql is deployed.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_test_reset_clear_day_zero_extras()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_deleted int;
  v_out jsonb := '{}'::jsonb;
  v_n int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  -- Stadium: live capacity back to base; clear fill progress
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Clubs' AND column_name = 'base_capacity'
  ) THEN
    UPDATE public."Clubs" c
    SET "Capacity" = coalesce(c.base_capacity, c."Capacity", 0)
    WHERE c."ShortName" IS NOT NULL
      AND coalesce(c."Capacity", 0) IS DISTINCT FROM coalesce(c.base_capacity, c."Capacity", 0);
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_out := v_out || jsonb_build_object('stadium_capacity_reset_rows', v_deleted);
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Clubs' AND column_name = 'stadium_fill_target_pct'
  ) THEN
    EXECUTE $sql$
      UPDATE public."Clubs"
      SET stadium_fill_target_pct = NULL,
          stadium_fill_last_month = NULL,
          stadium_fill_season_id = NULL,
          stadium_fill_updated_at = NULL
      WHERE stadium_fill_target_pct IS NOT NULL
         OR stadium_fill_last_month IS NOT NULL
         OR stadium_fill_season_id IS NOT NULL
         OR stadium_fill_updated_at IS NOT NULL
    $sql$;
  ELSIF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'Clubs' AND column_name = 'stadium_fill_season_id'
  ) THEN
    UPDATE public."Clubs"
    SET stadium_fill_season_id = NULL
    WHERE stadium_fill_season_id IS NOT NULL;
  END IF;

  -- Club-scoped scouting (owner_* boards intentionally kept)
  IF to_regclass('public.club_scouting_planner_player') IS NOT NULL THEN
    DELETE FROM public.club_scouting_planner_player WHERE true;
  END IF;
  IF to_regclass('public.club_scouting_planner') IS NOT NULL THEN
    DELETE FROM public.club_scouting_planner WHERE true;
  END IF;
  IF to_regclass('public.club_scouting_targets') IS NOT NULL THEN
    DELETE FROM public.club_scouting_targets WHERE true;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_out := v_out || jsonb_build_object('deleted_club_scouting_targets', v_deleted);
  END IF;

  -- Expiry wage bids (no season FK)
  IF to_regclass('public.contract_expiry_wage_bids') IS NOT NULL THEN
    DELETE FROM public.contract_expiry_wage_bids WHERE true;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_out := v_out || jsonb_build_object('deleted_expiry_wage_bids', v_deleted);
  END IF;

  -- Squad designations (star / OOO / FF)
  IF to_regclass('public.club_squad_player_designations') IS NOT NULL THEN
    DELETE FROM public.club_squad_player_designations WHERE true;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_out := v_out || jsonb_build_object('deleted_squad_designations', v_deleted);
  END IF;

  -- International nation managers (not covered by WC cycle wipe)
  IF to_regclass('public.international_nation_managers') IS NOT NULL THEN
    DELETE FROM public.international_nation_managers WHERE true;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_out := v_out || jsonb_build_object('deleted_intl_nation_managers', v_deleted);
  END IF;

  -- Discord runtime
  IF to_regclass('public.gpsl_discord_feed_queue') IS NOT NULL THEN
    DELETE FROM public.gpsl_discord_feed_queue WHERE true;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_out := v_out || jsonb_build_object('deleted_discord_queue', v_deleted);
  END IF;
  IF to_regclass('public.gpsl_discord_notifications_state') IS NOT NULL THEN
    DELETE FROM public.gpsl_discord_notifications_state WHERE true;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_out := v_out || jsonb_build_object('deleted_discord_notifications_state', v_deleted);
  END IF;
  IF to_regclass('public.gpsl_discord_whos_who_state') IS NOT NULL THEN
    DELETE FROM public.gpsl_discord_whos_who_state WHERE true;
  END IF;
  IF to_regclass('public.gpsl_transfer_ticker_cycle') IS NOT NULL THEN
    DELETE FROM public.gpsl_transfer_ticker_cycle WHERE true;
  END IF;

  -- Staff alerts (stale admin noise)
  IF to_regclass('public.gpsl_staff_alert_reads') IS NOT NULL THEN
    DELETE FROM public.gpsl_staff_alert_reads WHERE true;
  END IF;
  IF to_regclass('public.gpsl_staff_alerts') IS NOT NULL THEN
    DELETE FROM public.gpsl_staff_alerts WHERE true;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_out := v_out || jsonb_build_object('deleted_staff_alerts', v_deleted);
  END IF;

  -- Emergency / season loans if somehow still present (normally CASCADE with seasons)
  IF to_regclass('public.club_emergency_loans') IS NOT NULL THEN
    DELETE FROM public.club_emergency_loans WHERE true;
  END IF;
  IF to_regclass('public.club_season_loans') IS NOT NULL THEN
    DELETE FROM public.club_season_loans WHERE true;
  END IF;
  IF to_regclass('public.club_squad_minimum_enforcement') IS NOT NULL THEN
    DELETE FROM public.club_squad_minimum_enforcement WHERE true;
  END IF;

  v_out := v_out || jsonb_build_object('day_zero_extras_cleared', true);
  RETURN v_out;
END;
$function$;

COMMENT ON FUNCTION public.admin_test_reset_clear_day_zero_extras() IS
  'Vanilla reset extras: stadium base capacity, club scouting, expiry bids, designations, Discord state, intl managers.';

GRANT EXECUTE ON FUNCTION public.admin_test_reset_clear_day_zero_extras()
  TO authenticated;

-- Hook into live admin_test_reset_execute (before Phase G)
DO $hook$
DECLARE
  v_def text;
  v_new text;
  v_marker text := '-- Phase G: per-club counters';
  v_inject text := $i$
  -- Phase F4: day-zero extras (stadium / scouting / Discord / bids / designations)
  v_result := v_result || public.admin_test_reset_clear_day_zero_extras();

  -- Phase G: per-club counters$i$;
BEGIN
  SELECT pg_get_functiondef('public.admin_test_reset_execute(text,jsonb)'::regprocedure)
  INTO v_def;

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'admin_test_reset_execute missing — run admin_prelaunch_test_reset.sql first';
  END IF;

  IF position('admin_test_reset_clear_day_zero_extras' IN v_def) > 0 THEN
    RAISE NOTICE 'admin_test_reset_execute already hooks day_zero_extras';
    RETURN;
  END IF;

  IF position(v_marker IN v_def) = 0 THEN
    RAISE EXCEPTION 'Could not find Phase G marker in admin_test_reset_execute — patch manually';
  END IF;

  v_new := replace(v_def, v_marker, v_inject);
  EXECUTE v_new;
  RAISE NOTICE 'admin_test_reset_execute: hooked day_zero_extras before Phase G';
END;
$hook$;

NOTIFY pgrst, 'reload schema';
