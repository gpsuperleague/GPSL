-- =============================================================================
-- Vanilla reset: clear runtime admin switches, keep prize configuration
--
-- User rule:
--   Reset should turn these OFF / back to blank defaults:
--     - transfer_window_open
--     - draft_auction_enabled
--     - manager_draft_auction_enabled
--     - club_auction_enabled
--     - match_result_simulation_enabled
--     - match_result_simulation_settings (playback/cards/outcome bands/etc.)
--
--   Prize money configuration should stay as set.
--
-- Safe re-run. Run after admin_prelaunch_test_reset_gaps_20260905.sql so the
-- hooked day-zero extras function already exists.
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
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  -- Runtime/admin switches reset to day-zero defaults.
  -- Prize/tariff config is intentionally left untouched.
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'global_settings'
      AND column_name = 'transfer_window_open'
  ) THEN
    UPDATE public.global_settings
    SET
      transfer_window_open = false,
      draft_auction_enabled = false,
      manager_draft_auction_enabled = false,
      club_auction_enabled = false,
      match_result_simulation_enabled = false,
      match_result_simulation_settings = '{}'::jsonb
    WHERE id = 1;

    v_out := v_out || jsonb_build_object(
      'runtime_admin_flags_reset', true,
      'transfer_window_open', false,
      'draft_auction_enabled', false,
      'manager_draft_auction_enabled', false,
      'club_auction_enabled', false,
      'match_result_simulation_enabled', false,
      'match_result_simulation_settings_reset', true
    );
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
  'Vanilla reset extras: runtime admin flags OFF, stadium base capacity, club scouting, expiry bids, designations, Discord state, intl managers. Prize config kept.';

GRANT EXECUTE ON FUNCTION public.admin_test_reset_clear_day_zero_extras()
  TO authenticated;

NOTIFY pgrst, 'reload schema';
