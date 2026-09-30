-- =============================================================================
-- Season owner board (admin_owners_waiting_list.html) is admin-only.
--
-- Reverses the mod opening from mod_menu_rpc_access_20260929.sql for the RPCs
-- only that page uses. Owner tag / owner list / last logins stay mod-ok
-- because other Mod menu pages (Set Owner Tag, Discord join order) use them.
--
-- Safe re-run.
-- =============================================================================

DO $$
DECLARE
  v_names text[] := ARRAY[
    'waiting_list_admin',
    'admin_waiting_list_assign_club', 'admin_waiting_list_remove',
    'admin_waiting_list_reorder', 'admin_waiting_list_restore_join_order',
    'admin_waiting_list_set_absence', 'admin_waiting_list_set_auction_invite',
    'admin_waiting_list_set_season_confirmed',
    'admin_season1_invite_assign_next', 'admin_season1_invite_clear_number',
    'admin_season1_invite_mark_expired', 'admin_season1_invite_respond_on_behalf',
    'admin_season1_invite_status_map',
    'admin_owner_supporter_map',
    'admin_match_video_owner_metrics',
    'admin_supporter_payments_map'
  ];
  r record;
  v_def text;
  v_new text;
  v_fixed text[] := ARRAY[]::text[];
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
    v_new := regexp_replace(v_def, '(public\.)?is_gpsl_admin_or_mod\(\)', 'public.is_gpsl_admin()', 'g');
    IF v_new IS DISTINCT FROM v_def THEN
      EXECUTE v_new;
      v_fixed := v_fixed || r.sig;
    END IF;
  END LOOP;

  RAISE NOTICE 'Back to admin-only (%): %', coalesce(array_length(v_fixed, 1), 0), v_fixed;
END $$;

NOTIFY pgrst, 'reload schema';
