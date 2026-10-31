-- =============================================================================
-- Invoke discord-sync-roles action=sync_guild via pg_net (no JWT needed).
-- Walks Discord members, tag-links unlinked GPSL registry rows, sets roles.
-- Safe re-run. Call repeatedly until response done=true (or ~pages of guild).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_discord_roles_invoke_sync_guild(
  p_limit int DEFAULT 100,
  p_after text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, net
AS $function$
DECLARE
  v_url text;
  v_key text;
  v_enabled boolean;
  v_req_id bigint;
  v_limit int := greatest(1, least(coalesce(p_limit, 100), 100));
  v_after text := nullif(btrim(coalesce(p_after, '')), '');
BEGIN
  -- Callable from SQL editor / service_role; JWT admins use admin wrapper below.
  IF auth.uid() IS NOT NULL
     AND NOT public.is_gpsl_admin()
     AND NOT public.is_gpsl_mod() THEN
    RAISE EXCEPTION 'Admin or mod only';
  END IF;

  SELECT s.edge_function_url, s.invoke_key, s.enabled
  INTO v_url, v_key, v_enabled
  FROM public.gpsl_discord_roles_settings s
  WHERE s.id = 1;

  IF NOT coalesce(v_enabled, false)
     OR nullif(btrim(v_url), '') IS NULL
     OR nullif(btrim(v_key), '') IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'Role sync disabled or missing edge_function_url / invoke_key'
    );
  END IF;

  v_req_id := net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', v_key,
      'Authorization', 'Bearer ' || v_key,
      'x-discord-feed-key', v_key
    ),
    body := jsonb_build_object(
      'action', 'sync_guild',
      'limit', v_limit,
      'after', v_after,
      'auto_link', true,
      'source', 'gpsl_discord_roles_invoke_sync_guild'
    ),
    timeout_milliseconds := 150000
  );

  UPDATE public.gpsl_discord_roles_settings
  SET last_request_at = now(), last_error = NULL, updated_at = now()
  WHERE id = 1;

  RETURN jsonb_build_object(
    'ok', true,
    'request_id', v_req_id,
    'limit', v_limit,
    'after', v_after
  );
EXCEPTION
  WHEN undefined_function THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pg_net missing');
  WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', left(SQLERRM, 500));
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_roles_invoke_sync_guild(int, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_roles_invoke_sync_guild(int, text)
  TO authenticated, service_role, postgres;

-- Kick first page now (async via pg_net — check net._http_response)
SELECT public.gpsl_discord_roles_invoke_sync_guild(100, NULL) AS sync_guild_page1;

NOTIFY pgrst, 'reload schema';
