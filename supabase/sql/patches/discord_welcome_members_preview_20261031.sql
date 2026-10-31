-- Preview welcome_members (dry run) — lists recipients + message, sends nothing.
-- Safe re-run. Requires discord-welcome-pack deployed with dry_run support.

CREATE OR REPLACE FUNCTION public.gpsl_discord_welcome_members_preview(
  p_limit int DEFAULT 25,
  p_only_unsent boolean DEFAULT false
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
  v_sync_url text;
  v_req_id bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT s.edge_function_url, s.invoke_key, s.enabled
  INTO v_sync_url, v_key, v_enabled
  FROM public.gpsl_discord_roles_settings s
  WHERE s.id = 1;

  IF NOT coalesce(v_enabled, false)
     OR nullif(btrim(v_sync_url), '') IS NULL
     OR nullif(btrim(v_key), '') IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'Role sync settings missing edge_function_url / invoke_key'
    );
  END IF;

  v_url := regexp_replace(
    v_sync_url,
    '/functions/v1/[^/?#]+',
    '/functions/v1/discord-welcome-pack'
  );

  v_req_id := net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', v_key,
      'Authorization', 'Bearer ' || v_key,
      'x-discord-feed-key', v_key,
      'x-discord-welcome-key', v_key
    ),
    body := jsonb_build_object(
      'action', 'welcome_members',
      'dry_run', true,
      'limit', greatest(1, least(coalesce(p_limit, 25), 100)),
      'only_unsent', coalesce(p_only_unsent, false),
      'source', 'gpsl_discord_welcome_members_preview'
    ),
    timeout_milliseconds := 120000
  );

  RETURN jsonb_build_object(
    'ok', true,
    'request_id', v_req_id,
    'url', v_url,
    'hint', 'Check net._http_response for request_id — content has recipients + message_preview'
  );
EXCEPTION
  WHEN undefined_function THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pg_net missing');
  WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', left(SQLERRM, 500));
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_welcome_members_preview(int, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_welcome_members_preview(int, boolean)
  TO authenticated, service_role, postgres;

-- Kick a preview now (async via pg_net)
SELECT public.gpsl_discord_welcome_members_preview(50, false) AS preview_kick;
