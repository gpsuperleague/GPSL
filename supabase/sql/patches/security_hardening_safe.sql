-- =============================================================================
-- Safe security hardening (low / no product impact when already configured)
--
-- 1) Discord invoke_key: keep in DB for pg_net auto-flush, never expose to client
-- 2) Revoke dangerous EXECUTE from authenticated (service_role / admin wrappers remain)
--
-- Safe re-run.
--
-- ONE-TIME (only if auto-post has no key yet — SQL Editor as postgres/service):
--   UPDATE public.gpsl_discord_feed_settings
--   SET invoke_key = '<service_role JWT from Project Settings → API>'
--   WHERE id = 1;
--   -- Friendlies/gossip can copy from news via their cron patches / set RPCs.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Discord settings: never return invoke_key to the browser
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_discord_feed_get_auto()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_row public.gpsl_discord_feed_settings%rowtype;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT * INTO v_row FROM public.gpsl_discord_feed_settings WHERE id = 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'edge_function_url', NULL,
      'auto_flush_enabled', true,
      'has_key', false
    );
  END IF;

  RETURN jsonb_build_object(
    'edge_function_url', v_row.edge_function_url,
    'auto_flush_enabled', coalesce(v_row.auto_flush_enabled, true),
    'has_key', nullif(btrim(coalesce(v_row.invoke_key, '')), '') IS NOT NULL,
    'updated_at', v_row.updated_at
  );
END;
$function$;

-- URL + enabled only — invoke_key is never written from this RPC (ignore legacy arg).
CREATE OR REPLACE FUNCTION public.admin_discord_feed_set_auto(
  p_edge_function_url text,
  p_invoke_key text,
  p_enabled boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_has_key boolean;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  -- p_invoke_key intentionally ignored (do not store secrets from the browser).
  UPDATE public.gpsl_discord_feed_settings
  SET edge_function_url = nullif(btrim(coalesce(p_edge_function_url, '')), ''),
      auto_flush_enabled = coalesce(p_enabled, true),
      updated_at = now()
  WHERE id = 1;

  SELECT nullif(btrim(coalesce(invoke_key, '')), '') IS NOT NULL
  INTO v_has_key
  FROM public.gpsl_discord_feed_settings
  WHERE id = 1;

  RETURN jsonb_build_object(
    'ok', true,
    'auto_flush_enabled', coalesce(p_enabled, true),
    'has_url', nullif(btrim(coalesce(p_edge_function_url, '')), '') IS NOT NULL,
    'has_key', coalesce(v_has_key, false),
    'key_note', 'Invoke key is not set from the admin UI — use SQL Editor once if missing.'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_discord_friendlies_get_auto()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_url text;
  v_enabled boolean;
  v_has_key boolean;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT
    s.edge_function_url,
    s.auto_poll_enabled,
    nullif(btrim(coalesce(s.invoke_key, '')), '') IS NOT NULL
  INTO v_url, v_enabled, v_has_key
  FROM public.gpsl_discord_friendlies_settings s
  WHERE s.id = 1;

  RETURN jsonb_build_object(
    'edge_function_url', v_url,
    'auto_poll_enabled', coalesce(v_enabled, false),
    'has_key', coalesce(v_has_key, false)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_discord_friendlies_set_auto(
  p_edge_function_url text,
  p_invoke_key text DEFAULT NULL,
  p_enabled boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_has_key boolean;
  v_feed_key text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  INSERT INTO public.gpsl_discord_friendlies_settings (id)
  VALUES (1)
  ON CONFLICT (id) DO NOTHING;

  -- Never accept browser-supplied keys. Prefer existing friendlies key, else copy from news.
  SELECT nullif(btrim(coalesce(invoke_key, '')), '')
  INTO v_feed_key
  FROM public.gpsl_discord_feed_settings
  WHERE id = 1;

  UPDATE public.gpsl_discord_friendlies_settings
  SET edge_function_url = nullif(btrim(coalesce(p_edge_function_url, '')), ''),
      invoke_key = coalesce(
        nullif(btrim(coalesce(invoke_key, '')), ''),
        v_feed_key
      ),
      auto_poll_enabled = coalesce(p_enabled, true),
      updated_at = now()
  WHERE id = 1;

  SELECT nullif(btrim(coalesce(invoke_key, '')), '') IS NOT NULL
  INTO v_has_key
  FROM public.gpsl_discord_friendlies_settings
  WHERE id = 1;

  RETURN jsonb_build_object(
    'ok', true,
    'auto_poll_enabled', coalesce(p_enabled, true),
    'has_url', nullif(btrim(coalesce(p_edge_function_url, '')), '') IS NOT NULL,
    'has_key', coalesce(v_has_key, false),
    'key_note', 'Key is copied from Discord News settings if present; not set from the browser.'
  );
END;
$function$;

-- Gossip settings (table may exist from gossip cron patch)
DO $do$
BEGIN
  IF to_regclass('public.gpsl_discord_transfer_gossip_settings') IS NULL THEN
    RETURN;
  END IF;

  EXECUTE $fn$
    CREATE OR REPLACE FUNCTION public.admin_discord_transfer_gossip_get_auto()
    RETURNS jsonb
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    SET search_path = public
    AS $function$
    DECLARE
      v_url text;
      v_enabled boolean;
      v_has_key boolean;
    BEGIN
      IF NOT public.is_gpsl_admin() THEN
        RAISE EXCEPTION 'Admin only';
      END IF;

      SELECT
        s.edge_function_url,
        s.auto_poll_enabled,
        nullif(btrim(coalesce(s.invoke_key, '')), '') IS NOT NULL
      INTO v_url, v_enabled, v_has_key
      FROM public.gpsl_discord_transfer_gossip_settings s
      WHERE s.id = 1;

      RETURN jsonb_build_object(
        'edge_function_url', v_url,
        'auto_poll_enabled', coalesce(v_enabled, false),
        'has_key', coalesce(v_has_key, false)
      );
    END;
    $function$;
  $fn$;

  EXECUTE $fn$
    CREATE OR REPLACE FUNCTION public.admin_discord_transfer_gossip_set_auto(
      p_edge_function_url text,
      p_invoke_key text DEFAULT NULL,
      p_enabled boolean DEFAULT true
    )
    RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = public
    AS $function$
    DECLARE
      v_has_key boolean;
      v_feed_key text;
    BEGIN
      IF NOT public.is_gpsl_admin() THEN
        RAISE EXCEPTION 'Admin only';
      END IF;

      INSERT INTO public.gpsl_discord_transfer_gossip_settings (id)
      VALUES (1)
      ON CONFLICT (id) DO NOTHING;

      SELECT nullif(btrim(coalesce(invoke_key, '')), '')
      INTO v_feed_key
      FROM public.gpsl_discord_feed_settings
      WHERE id = 1;

      UPDATE public.gpsl_discord_transfer_gossip_settings
      SET edge_function_url = nullif(btrim(coalesce(p_edge_function_url, '')), ''),
          invoke_key = coalesce(
            nullif(btrim(coalesce(invoke_key, '')), ''),
            v_feed_key
          ),
          auto_poll_enabled = coalesce(p_enabled, true),
          updated_at = now()
      WHERE id = 1;

      SELECT nullif(btrim(coalesce(invoke_key, '')), '') IS NOT NULL
      INTO v_has_key
      FROM public.gpsl_discord_transfer_gossip_settings
      WHERE id = 1;

      RETURN jsonb_build_object(
        'ok', true,
        'auto_poll_enabled', coalesce(p_enabled, true),
        'has_url', nullif(btrim(coalesce(p_edge_function_url, '')), '') IS NOT NULL,
        'has_key', coalesce(v_has_key, false),
        'key_note', 'Key is copied from Discord News settings if present; not set from the browser.'
      );
    END;
    $function$;
  $fn$;

  GRANT EXECUTE ON FUNCTION public.admin_discord_transfer_gossip_get_auto() TO authenticated;
  GRANT EXECUTE ON FUNCTION public.admin_discord_transfer_gossip_set_auto(text, text, boolean) TO authenticated;
END;
$do$;

-- Column privileges: authenticated cannot read invoke_key (use get_* RPCs instead)
REVOKE ALL ON TABLE public.gpsl_discord_feed_settings FROM authenticated;
GRANT SELECT (id, edge_function_url, auto_flush_enabled, updated_at)
  ON public.gpsl_discord_feed_settings TO authenticated;

REVOKE ALL ON TABLE public.gpsl_discord_friendlies_settings FROM authenticated;
GRANT SELECT (id, edge_function_url, auto_poll_enabled, updated_at)
  ON public.gpsl_discord_friendlies_settings TO authenticated;

DO $g$
BEGIN
  IF to_regclass('public.gpsl_discord_transfer_gossip_settings') IS NOT NULL THEN
    REVOKE ALL ON TABLE public.gpsl_discord_transfer_gossip_settings FROM authenticated;
    GRANT SELECT (id, edge_function_url, auto_poll_enabled, updated_at)
      ON public.gpsl_discord_transfer_gossip_settings TO authenticated;
  END IF;
END;
$g$;

GRANT EXECUTE ON FUNCTION public.admin_discord_feed_get_auto() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_discord_feed_set_auto(text, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_discord_friendlies_get_auto() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_discord_friendlies_set_auto(text, text, boolean) TO authenticated;

-- ---------------------------------------------------------------------------
-- Dangerous RPCs: authenticated must not call directly
-- Admin UI already uses admin_transferengine_run(); Edge uses service_role.
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.transferengine_run() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.transferengine_run() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_run() TO service_role;

REVOKE ALL ON FUNCTION public.transferengine_run_report() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.transferengine_run_report() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.transferengine_run_report() TO service_role;

-- Keep admin wrapper for Transfer management UI
GRANT EXECUTE ON FUNCTION public.admin_transferengine_run() TO authenticated;

DO $prize$
BEGIN
  IF to_regprocedure('public.prize_grant_inventory_item(text,text,int,text,bigint,text,jsonb)') IS NOT NULL THEN
    REVOKE ALL ON FUNCTION public.prize_grant_inventory_item(text, text, int, text, bigint, text, jsonb) FROM PUBLIC;
    REVOKE ALL ON FUNCTION public.prize_grant_inventory_item(text, text, int, text, bigint, text, jsonb) FROM authenticated;
    GRANT EXECUTE ON FUNCTION public.prize_grant_inventory_item(text, text, int, text, bigint, text, jsonb) TO service_role;
  END IF;
END;
$prize$;

DO $loan$
BEGIN
  IF to_regprocedure('public.club_loan_reverse_premature_collections(text)') IS NOT NULL THEN
    REVOKE ALL ON FUNCTION public.club_loan_reverse_premature_collections(text) FROM PUBLIC;
    REVOKE ALL ON FUNCTION public.club_loan_reverse_premature_collections(text) FROM authenticated;
    GRANT EXECUTE ON FUNCTION public.club_loan_reverse_premature_collections(text) TO service_role;
  END IF;
END;
$loan$;

DO $inbox$
BEGIN
  IF to_regprocedure('public.owner_inbox_notify_all_clubs(text,text,text,text,text,bigint)') IS NOT NULL THEN
    REVOKE ALL ON FUNCTION public.owner_inbox_notify_all_clubs(text, text, text, text, text, bigint) FROM PUBLIC;
    REVOKE ALL ON FUNCTION public.owner_inbox_notify_all_clubs(text, text, text, text, text, bigint) FROM authenticated;
    GRANT EXECUTE ON FUNCTION public.owner_inbox_notify_all_clubs(text, text, text, text, text, bigint) TO service_role;
  END IF;
END;
$inbox$;

NOTIFY pgrst, 'reload schema';
