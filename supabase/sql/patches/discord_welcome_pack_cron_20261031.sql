-- =============================================================================
-- Welcome pack via Supabase cron (no VPS / always-on Discord bot).
--
-- Every 2 minutes: edge discord-welcome-pack action=welcome_newcomers
-- finds guild members not yet in gpsl_discord_welcome_sent and DMs them.
--
-- Run seed_existing ONCE after deploy so current members are not spammed.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_discord_welcome_tick()
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
  v_sync_url text;
BEGIN
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

  -- Same project, welcome-pack function
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
      'action', 'welcome_newcomers',
      'limit', 12,
      'source', 'gpsl_discord_welcome_tick'
    ),
    timeout_milliseconds := 120000
  );

  RETURN jsonb_build_object('ok', true, 'request_id', v_req_id, 'url', v_url);
EXCEPTION
  WHEN undefined_function THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pg_net missing');
  WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', left(SQLERRM, 500));
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_welcome_tick() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_welcome_tick()
  TO service_role, postgres;

-- One-shot seed (mark current guild as already welcomed — no DMs)
CREATE OR REPLACE FUNCTION public.gpsl_discord_welcome_seed_existing()
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
  v_sync_url text;
BEGIN
  SELECT s.edge_function_url, s.invoke_key, s.enabled
  INTO v_sync_url, v_key, v_enabled
  FROM public.gpsl_discord_roles_settings s
  WHERE s.id = 1;

  IF NOT coalesce(v_enabled, false)
     OR nullif(btrim(v_sync_url), '') IS NULL
     OR nullif(btrim(v_key), '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'missing invoke settings');
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
      'action', 'seed_existing',
      'source', 'gpsl_discord_welcome_seed_existing'
    ),
    timeout_milliseconds := 120000
  );

  RETURN jsonb_build_object('ok', true, 'request_id', v_req_id);
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', left(SQLERRM, 500));
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_welcome_seed_existing() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_welcome_seed_existing()
  TO service_role, postgres;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('gpsl-discord-welcome-newcomers');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'gpsl-discord-welcome-newcomers',
      '*/2 * * * *',
      $$SELECT public.gpsl_discord_welcome_tick();$$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron schedule skipped: %', SQLERRM;
END;
$cron$;

-- Seed current members first (async via pg_net)
SELECT public.gpsl_discord_welcome_seed_existing() AS seed;

SELECT jobname, schedule, command
FROM cron.job
WHERE jobname = 'gpsl-discord-welcome-newcomers';

NOTIFY pgrst, 'reload schema';
