-- =============================================================================
-- GPSL Mod role
--
-- • gpsl_site_mods — granted mods (admin manages)
-- • is_gpsl_mod() / is_gpsl_admin_or_mod()
-- • admin_mod_list / admin_mod_grant / admin_mod_revoke
-- • Opens a curated allowlist of admin RPCs to mods (not full admin)
--
-- Run once in Supabase SQL Editor. Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpsl_site_mods (
  user_id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  granted_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  granted_at timestamptz NOT NULL DEFAULT now(),
  note text
);

COMMENT ON TABLE public.gpsl_site_mods IS
  'Site moderators — limited admin tools (waiting list, Discord feeds, fines, internationals selection, etc.).';

ALTER TABLE public.gpsl_site_mods ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_site_mods_select_admin ON public.gpsl_site_mods;
CREATE POLICY gpsl_site_mods_select_admin
  ON public.gpsl_site_mods
  FOR SELECT
  TO authenticated
  USING (public.is_gpsl_admin());

GRANT SELECT ON public.gpsl_site_mods TO authenticated;

CREATE OR REPLACE FUNCTION public.is_gpsl_mod()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.gpsl_site_mods m
    WHERE m.user_id = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION public.is_gpsl_admin_or_mod()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.is_gpsl_admin() OR public.is_gpsl_mod();
$$;

GRANT EXECUTE ON FUNCTION public.is_gpsl_mod() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_gpsl_admin_or_mod() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_gpsl_mod() TO service_role;
GRANT EXECUTE ON FUNCTION public.is_gpsl_admin_or_mod() TO service_role;

-- Client helper (explicit name for PostgREST)
CREATE OR REPLACE FUNCTION public.gpsl_am_mod()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.is_gpsl_mod();
$$;

GRANT EXECUTE ON FUNCTION public.gpsl_am_mod() TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_mod_list()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  RETURN coalesce(
    (
      SELECT jsonb_agg(
        jsonb_build_object(
          'user_id', m.user_id,
          'email', u.email,
          'granted_at', m.granted_at,
          'granted_by', m.granted_by,
          'note', m.note,
          'owner_tag', r.owner_tag,
          'club_short_name', c."ShortName"
        )
        ORDER BY lower(coalesce(u.email, ''))
      )
      FROM public.gpsl_site_mods m
      LEFT JOIN auth.users u ON u.id = m.user_id
      LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = m.user_id
      LEFT JOIN public."Clubs" c ON c.owner_id = m.user_id
    ),
    '[]'::jsonb
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_mod_grant(
  p_email text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_uid uuid;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_email = '' THEN
    RAISE EXCEPTION 'Email required';
  END IF;

  IF v_email = 'rotavator66@outlook.com' THEN
    RAISE EXCEPTION 'League admin does not need a mod grant';
  END IF;

  SELECT u.id INTO v_uid
  FROM auth.users u
  WHERE lower(u.email) = v_email
  LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'No auth user for %', v_email;
  END IF;

  INSERT INTO public.gpsl_site_mods (user_id, granted_by, note)
  VALUES (v_uid, auth.uid(), nullif(btrim(coalesce(p_note, '')), ''))
  ON CONFLICT (user_id) DO UPDATE
    SET granted_by = excluded.granted_by,
        granted_at = now(),
        note = coalesce(excluded.note, public.gpsl_site_mods.note);

  RETURN jsonb_build_object(
    'ok', true,
    'user_id', v_uid,
    'email', v_email
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_mod_revoke(p_email text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_uid uuid;
  v_deleted int := 0;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF v_email = '' THEN
    RAISE EXCEPTION 'Email required';
  END IF;

  SELECT u.id INTO v_uid
  FROM auth.users u
  WHERE lower(u.email) = v_email
  LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'No auth user for %', v_email;
  END IF;

  DELETE FROM public.gpsl_site_mods m
  WHERE m.user_id = v_uid;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'email', v_email,
    'revoked', v_deleted > 0
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_mod_list() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_mod_grant(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_mod_revoke(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Open curated RPCs to mods (rewrite permission checks in place)
-- ---------------------------------------------------------------------------

DO $open_mod_rpcs$
DECLARE
  r record;
  src text;
  new_src text;
  funcs text[] := ARRAY[
    'admin_cancel_open_transfers_preview',
    'admin_cancel_open_transfers',
    'competition_admin_apply_fine',
    'competition_admin_save_fine_tariff',
    'competition_admin_adjust_league_points',
    'competition_admin_seed_fine_tariffs',
    'owner_inbox_notify_fine_applied',
    'admin_club_season_checklist',
    'admin_notify_club_checklist_issues',
    'natter_admin_list_posts',
    'natter_admin_delete_post',
    'admin_owner_list',
    'admin_owner_set_tag',
    'waiting_list_admin',
    'admin_waiting_list_move',
    'admin_waiting_list_restore_join_order',
    'admin_waiting_list_set_absence',
    'admin_waiting_list_set_season_confirmed',
    'admin_waiting_list_invite_auction',
    'admin_waiting_list_assign_club',
    'admin_waiting_list_remove',
    'admin_waiting_list_add_member',
    'admin_list_club_holidays',
    'admin_club_holiday_cancel',
    'admin_club_holiday_amend',
    'admin_club_holiday_book',
    'admin_discord_feed_set_auto',
    'admin_discord_feed_flush_now',
    'admin_discord_publish_whos_who',
    'admin_discord_publish_league_tables',
    'admin_discord_notifications_tick_now',
    'admin_discord_requeue_natter_posts',
    'admin_discord_requeue_rate_limited',
    'admin_discord_friendlies_set_auto',
    'admin_gpsl_friendlies_overview',
    'admin_discord_transfer_gossip_set_auto',
    'admin_gpsl_transfer_gossip_overview',
    'gpsl_sport_list_editions',
    'competition_admin_regenerate_gpsl_sport',
    'admin_list_suspension_appeals',
    'admin_review_suspension_appeal',
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
    'competition_owner_ranking_recompute_all'
  ];
  opened int := 0;
  skipped int := 0;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = ANY (funcs)
  LOOP
    src := pg_get_functiondef(r.oid);
    new_src := src;
    new_src := replace(new_src, 'NOT public.is_gpsl_admin()', 'NOT public.is_gpsl_admin_or_mod()');
    new_src := replace(new_src, 'public.is_gpsl_admin() IS NOT TRUE', 'public.is_gpsl_admin_or_mod() IS NOT TRUE');
    -- RLS-style checks inside some functions
    new_src := replace(new_src, 'AND NOT public.is_gpsl_admin()', 'AND NOT public.is_gpsl_admin_or_mod()');

    IF new_src IS DISTINCT FROM src THEN
      EXECUTE new_src;
      opened := opened + 1;
    ELSE
      skipped := skipped + 1;
      RAISE NOTICE 'gpsl_mods: no admin check pattern in % (oid %)', r.proname, r.oid;
    END IF;
  END LOOP;

  RAISE NOTICE 'gpsl_mods: opened % function overload(s); % unchanged', opened, skipped;
END;
$open_mod_rpcs$;

-- Login-events SELECT for mods (last-login page uses SECURITY DEFINER RPC,
-- but keep policy consistent if clients query the table).
DO $login_events_policy$
BEGIN
  IF to_regclass('public.owner_site_login_events') IS NULL THEN
    RAISE NOTICE 'gpsl_mods: owner_site_login_events missing — skip policy';
    RETURN;
  END IF;

  DROP POLICY IF EXISTS owner_site_login_events_select_admin ON public.owner_site_login_events;
  CREATE POLICY owner_site_login_events_select_admin
    ON public.owner_site_login_events
    FOR SELECT
    TO authenticated
    USING (public.is_gpsl_admin_or_mod());
END;
$login_events_policy$;
