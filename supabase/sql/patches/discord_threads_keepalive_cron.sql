-- =============================================================================
-- Discord thread keep-alive — pg_cron + pg_net → discord-threads-keepalive
-- =============================================================================
-- Deploy first:
--   supabase functions deploy discord-threads-keepalive
-- Secrets:
--   DISCORD_BOT_TOKEN, DISCORD_GUILD_ID
--   DISCORD_KEEPALIVE_PARENT_CHANNEL_IDS   (comma-separated forum/channel IDs)
--   DISCORD_FEED_INVOKE_KEY (or DISCORD_KEEPALIVE_INVOKE_KEY)
--
-- Bot needs Manage Threads on those parent channels.
-- Cron: every 30 minutes. Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpsl_discord_threads_keepalive_settings (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  edge_function_url text,
  invoke_key text,
  auto_poll_enabled boolean NOT NULL DEFAULT false,
  last_run_at timestamptz,
  last_result jsonb,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.gpsl_discord_threads_keepalive_settings (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.gpsl_discord_threads_keepalive_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_discord_threads_keepalive_settings_admin
  ON public.gpsl_discord_threads_keepalive_settings;
CREATE POLICY gpsl_discord_threads_keepalive_settings_admin
  ON public.gpsl_discord_threads_keepalive_settings
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT, UPDATE ON public.gpsl_discord_threads_keepalive_settings TO authenticated;
GRANT ALL ON public.gpsl_discord_threads_keepalive_settings TO service_role;

CREATE OR REPLACE FUNCTION public.admin_discord_threads_keepalive_set_auto(
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
  v_url text := nullif(btrim(coalesce(p_edge_function_url, '')), '');
  v_key text := nullif(btrim(coalesce(p_invoke_key, '')), '');
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  INSERT INTO public.gpsl_discord_threads_keepalive_settings (id)
  VALUES (1)
  ON CONFLICT (id) DO NOTHING;

  UPDATE public.gpsl_discord_threads_keepalive_settings
  SET edge_function_url = coalesce(v_url, edge_function_url),
      invoke_key = coalesce(v_key, invoke_key),
      auto_poll_enabled = coalesce(p_enabled, auto_poll_enabled),
      updated_at = now()
  WHERE id = 1;

  RETURN jsonb_build_object(
    'ok', true,
    'auto_poll_enabled', coalesce(p_enabled, true),
    'has_url', (
      SELECT nullif(btrim(coalesce(edge_function_url, '')), '') IS NOT NULL
      FROM public.gpsl_discord_threads_keepalive_settings WHERE id = 1
    ),
    'has_key', (
      SELECT nullif(btrim(coalesce(invoke_key, '')), '') IS NOT NULL
      FROM public.gpsl_discord_threads_keepalive_settings WHERE id = 1
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_discord_threads_keepalive_set_auto(text, text, boolean)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.gpsl_discord_threads_keepalive_request()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, net
AS $function$
DECLARE
  v_url text;
  v_key text;
  v_enabled boolean;
BEGIN
  SELECT s.edge_function_url, s.invoke_key, s.auto_poll_enabled
  INTO v_url, v_key, v_enabled
  FROM public.gpsl_discord_threads_keepalive_settings s
  WHERE s.id = 1;

  IF NOT coalesce(v_enabled, false) THEN
    RETURN;
  END IF;
  IF v_url IS NULL OR btrim(v_url) = '' OR v_key IS NULL OR btrim(v_key) = '' THEN
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000
  );

  UPDATE public.gpsl_discord_threads_keepalive_settings
  SET last_run_at = now(), updated_at = now()
  WHERE id = 1;
EXCEPTION
  WHEN undefined_function THEN
    RAISE WARNING 'gpsl_discord_threads_keepalive_request: pg_net missing';
  WHEN OTHERS THEN
    RAISE WARNING 'gpsl_discord_threads_keepalive_request failed: %', SQLERRM;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_threads_keepalive_request() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_threads_keepalive_request() TO postgres;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_threads_keepalive_request() TO service_role;

-- Bootstrap URL + key from Discord News / Friendlies settings when available
DO $boot$
DECLARE
  v_feed_url text;
  v_feed_key text;
  v_url text;
  v_cur_url text;
  v_cur_key text;
BEGIN
  BEGIN
    SELECT nullif(btrim(edge_function_url), ''), nullif(btrim(invoke_key), '')
    INTO v_feed_url, v_feed_key
    FROM public.gpsl_discord_feed_settings
    WHERE id = 1;
  EXCEPTION WHEN undefined_table THEN
    v_feed_url := NULL;
    v_feed_key := NULL;
  END;

  SELECT nullif(btrim(edge_function_url), ''), nullif(btrim(invoke_key), '')
  INTO v_cur_url, v_cur_key
  FROM public.gpsl_discord_threads_keepalive_settings
  WHERE id = 1;

  IF v_feed_url IS NOT NULL THEN
    v_url := regexp_replace(
      v_feed_url,
      'discord-sky-feed/?$',
      'discord-threads-keepalive'
    );
    IF v_url = v_feed_url THEN
      v_url :=
        'https://omyyogfumrjoaweuawjn.supabase.co/functions/v1/discord-threads-keepalive';
    END IF;
  ELSE
    v_url :=
      'https://omyyogfumrjoaweuawjn.supabase.co/functions/v1/discord-threads-keepalive';
  END IF;

  UPDATE public.gpsl_discord_threads_keepalive_settings
  SET edge_function_url = coalesce(v_cur_url, v_url),
      invoke_key = coalesce(v_cur_key, v_feed_key),
      auto_poll_enabled = CASE
        WHEN coalesce(v_cur_key, v_feed_key) IS NOT NULL THEN true
        ELSE auto_poll_enabled
      END,
      updated_at = now()
  WHERE id = 1;
END;
$boot$;

DO $do$
DECLARE
  v_job record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE WARNING 'pg_cron not enabled — invoke discord-threads-keepalive manually';
    RETURN;
  END IF;

  FOR v_job IN
    SELECT jobid FROM cron.job WHERE jobname = 'gpsl-discord-threads-keepalive'
  LOOP
    PERFORM cron.unschedule(v_job.jobid);
  END LOOP;

  -- Every 30 minutes is enough for 1h/24h/3d/1w auto-archive windows
  PERFORM cron.schedule(
    'gpsl-discord-threads-keepalive',
    '*/30 * * * *',
    $$SELECT public.gpsl_discord_threads_keepalive_request();$$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not schedule threads keepalive cron: %', SQLERRM;
END;
$do$;

NOTIFY pgrst, 'reload schema';
