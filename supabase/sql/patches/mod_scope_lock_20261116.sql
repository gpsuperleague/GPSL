-- Take destructive RPCs back off site mods.
-- Day-to-day tools (checklist, natter, holidays, video reports, queue push) stay.

DO $lock_mod_rpcs$
DECLARE
  v_names text[] := ARRAY[
    'competition_admin_apply_fine',
    'competition_admin_save_fine_tariff',
    'competition_admin_adjust_league_points',
    'competition_admin_seed_fine_tariffs',
    'owner_inbox_notify_fine_applied',
    'admin_set_auto_fines',
    'admin_set_auto_fine_switch',
    'admin_delete_fine_tariff',
    'admin_cancel_open_transfers',
    'admin_cancel_open_transfers_preview',
    'admin_injury_settings_get',
    'admin_injury_settings_save',
    'admin_injury_club_risks',
    'admin_injury_active_list',
    'competition_injury_init_season_risks',
    'competition_injury_tick_preseason_month',
    'international_admin_open_selection',
    'international_admin_close_selection',
    'international_admin_assign_nation',
    'international_admin_release_nation',
    'international_admin_skip_current_pick',
    'competition_owner_ranking_recompute_all',
    'competition_admin_regenerate_gpsl_sport',
    'gpsl_sport_list_editions',
    'admin_discord_feed_set_auto',
    'admin_discord_publish_whos_who',
    'admin_discord_publish_league_tables',
    'admin_discord_publish_intl_tables',
    'admin_discord_notifications_tick_now',
    'admin_discord_requeue_natter_posts',
    'admin_discord_results_digest_now',
    'admin_discord_all_results_digest_now',
    'admin_discord_deals_digest_now',
    'admin_competition_announce_clinches',
    'admin_discord_job_center_post_now',
    'admin_discord_friendlies_set_auto',
    'admin_discord_transfer_gossip_set_auto',
    'admin_match_video_set_amounts',
    'match_video_process_all_penalties',
    'match_video_rescind_fines_inside_grace',
    'admin_waiting_list_move',
    'admin_waiting_list_restore_join_order',
    'admin_waiting_list_set_absence',
    'admin_waiting_list_set_season_confirmed',
    'admin_waiting_list_invite_auction',
    'admin_waiting_list_assign_club',
    'admin_waiting_list_remove',
    'admin_waiting_list_add_member',
    'waiting_list_admin'
  ];
  r record;
  v_def text;
  v_new text;
  v_locked int := 0;
BEGIN
  FOR r IN
    SELECT p.oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
      AND p.proname = ANY (v_names)
  LOOP
    v_def := pg_get_functiondef(r.oid);
    v_new := replace(v_def, 'is_gpsl_admin_or_mod()', 'is_gpsl_admin()');
    IF v_new IS DISTINCT FROM v_def THEN
      EXECUTE v_new;
      v_locked := v_locked + 1;
    END IF;
  END LOOP;
  RAISE NOTICE 'mod scope lock rewrote % function(s)', v_locked;
END;
$lock_mod_rpcs$;

NOTIFY pgrst, 'reload schema';

SELECT
  (
    SELECT count(*)
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = ANY (ARRAY[
        'competition_admin_apply_fine',
        'admin_cancel_open_transfers',
        'admin_injury_settings_save',
        'international_admin_assign_nation',
        'competition_admin_regenerate_gpsl_sport',
        'admin_discord_feed_set_auto',
        'admin_discord_job_center_post_now',
        'match_video_process_all_penalties',
        'admin_waiting_list_assign_club'
      ])
      AND pg_get_functiondef(p.oid) LIKE '%is_gpsl_admin_or_mod()%'
  ) AS still_open,
  (
    SELECT count(*)
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = ANY (ARRAY[
        'admin_discord_feed_flush_now',
        'natter_admin_delete_post',
        'admin_review_suspension_appeal',
        'match_video_admin_link'
      ])
      AND pg_get_functiondef(p.oid) LIKE '%is_gpsl_admin_or_mod()%'
  ) AS still_for_mods;
