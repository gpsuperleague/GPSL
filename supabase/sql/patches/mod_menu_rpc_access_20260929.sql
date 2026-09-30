-- =============================================================================
-- Mod menu: let gpsl_site_mods use the tools listed in mod_nav.js.
--
-- Before is_gpsl_admin_security_fix_20260929.sql, is_gpsl_admin() returned
-- true for everyone, so mods could use these admin-gated RPCs by accident.
-- This swaps is_gpsl_admin() → is_gpsl_admin_or_mod() inside ONLY the
-- functions the Mod menu pages call. Everything else stays admin-only.
--
-- Deliberately NOT included (admin decisions): auto-fines on/off, fine tariff
-- edits, league points adjustments, injury settings save / ticks, the rest of
-- the Transfers page, owner archive/remove/change club, login security map.
--
-- Safe re-run.
-- =============================================================================

DO $$
DECLARE
  v_names text[] := ARRAY[
    -- Owners: tag / Discord join order (season owner board is admin-only)
    'admin_owner_list', 'admin_owner_set_tag', 'owner_registry_resolve_tag',
    'admin_owner_last_logins',
    -- Owners: holidays / natter
    'admin_list_club_holidays', 'admin_club_holiday_book',
    'admin_club_holiday_amend', 'admin_club_holiday_cancel',
    'natter_admin_list_posts', 'natter_admin_delete_post',
    -- Discord & media
    'admin_discord_feed_get_auto', 'admin_discord_feed_set_auto',
    'admin_discord_feed_flush_now', 'admin_discord_notifications_tick_now',
    'admin_discord_results_digest_now', 'admin_discord_all_results_digest_now',
    'admin_discord_deals_digest_now', 'admin_discord_publish_league_tables',
    'admin_discord_publish_intl_tables', 'admin_discord_publish_whos_who',
    'admin_discord_requeue_natter_posts', 'admin_discord_requeue_rate_limited',
    'admin_competition_announce_clinches',
    'admin_discord_friendlies_get_auto', 'admin_discord_friendlies_set_auto',
    'admin_gpsl_friendlies_overview',
    'admin_discord_transfer_gossip_get_auto', 'admin_discord_transfer_gossip_set_auto',
    'admin_gpsl_transfer_gossip_overview',
    'admin_discord_match_videos_get_auto', 'admin_discord_match_videos_set_auto',
    'match_video_admin_recent', 'match_video_admin_link',
    'match_video_process_all_penalties', 'match_video_rescind_fines_inside_grace',
    'fixture_network_incident_admin_list', 'fixture_network_incident_admin_resolve',
    'competition_admin_regenerate_gpsl_sport', 'gpsl_sport_list_editions',
    -- Season ops
    'admin_notify_club_checklist_issues',
    'competition_admin_apply_fine', 'owner_inbox_notify_fine_applied',
    'gpsl_auto_fines_status',
    'admin_list_suspension_appeals', 'admin_review_suspension_appeal',
    'admin_injury_active_list', 'admin_injury_club_risks', 'admin_injury_settings_get',
    'admin_cancel_open_transfers', 'admin_cancel_open_transfers_preview',
    -- Nations
    'international_admin_open_selection', 'international_admin_close_selection',
    'international_admin_skip_current_pick',
    'international_admin_assign_nation', 'international_admin_release_nation',
    'competition_owner_ranking_recompute_all'
  ];
  r record;
  v_def text;
  v_new text;
  v_fixed text[] := ARRAY[]::text[];
  v_unchanged text[] := ARRAY[]::text[];
  v_missing text[];
BEGIN
  FOR r IN
    SELECT p.oid, p.oid::regprocedure::text AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
      AND p.proname = ANY (v_names)
  LOOP
    v_def := pg_get_functiondef(r.oid);
    v_new := regexp_replace(v_def, '(public\.)?is_gpsl_admin\(\)', 'public.is_gpsl_admin_or_mod()', 'g');
    IF v_new IS DISTINCT FROM v_def THEN
      EXECUTE v_new;
      v_fixed := v_fixed || r.sig;
    ELSE
      v_unchanged := v_unchanged || r.sig;
    END IF;
  END LOOP;

  SELECT array_agg(x) INTO v_missing
  FROM unnest(v_names) x
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = x
  );

  RAISE NOTICE 'Opened to mods (%): %', coalesce(array_length(v_fixed, 1), 0), v_fixed;
  RAISE NOTICE 'Already mod-ok / other gate (%): %', coalesce(array_length(v_unchanged, 1), 0), v_unchanged;
  RAISE NOTICE 'Not in DB (%): %', coalesce(array_length(v_missing, 1), 0), v_missing;
END $$;

-- Tables the mod pages read directly: add a mod SELECT policy alongside
-- whatever admin/owner policies already exist (policies are OR'd).
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'gpsl_discord_feed_queue',
    'competition_fine_applied',
    'competition_fine_tariff',
    'gpsl_sport_editions'
  ]
  LOOP
    IF to_regclass('public.' || t) IS NULL THEN
      CONTINUE;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = t AND c.relrowsecurity
    ) THEN
      CONTINUE;
    END IF;
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_mod_select', t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (public.is_gpsl_admin_or_mod())',
      t || '_mod_select', t
    );
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
