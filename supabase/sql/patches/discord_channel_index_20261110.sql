-- =============================================================================
-- Discord channel index in #where-to-go
-- The bot edits the same message. No extra Edge secret.
-- Deploy first: supabase functions deploy discord-channel-index
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpsl_discord_channel_index_settings (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  edge_function_url text,
  invoke_key text,
  auto_poll_enabled boolean NOT NULL DEFAULT false,
  message_ids text[] NOT NULL DEFAULT '{}',
  content_hash text,
  last_run_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.gpsl_discord_channel_index_settings (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.gpsl_discord_channel_index_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_discord_channel_index_settings_admin
  ON public.gpsl_discord_channel_index_settings;
CREATE POLICY gpsl_discord_channel_index_settings_admin
  ON public.gpsl_discord_channel_index_settings
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT, UPDATE ON public.gpsl_discord_channel_index_settings TO authenticated;
GRANT ALL ON public.gpsl_discord_channel_index_settings TO service_role;

CREATE OR REPLACE FUNCTION public.gpsl_discord_channel_index_request()
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
  FROM public.gpsl_discord_channel_index_settings s
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
      'Authorization', 'Bearer ' || v_key,
      'x-discord-feed-key', v_key
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000
  );

  UPDATE public.gpsl_discord_channel_index_settings
  SET last_run_at = now(), updated_at = now()
  WHERE id = 1;
EXCEPTION
  WHEN undefined_function THEN
    RAISE WARNING 'gpsl_discord_channel_index_request: pg_net missing';
  WHEN OTHERS THEN
    RAISE WARNING 'gpsl_discord_channel_index_request failed: %', SQLERRM;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_channel_index_request() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_channel_index_request() TO postgres, service_role;

DO $boot$
DECLARE
  v_feed_url text;
  v_feed_key text;
  v_url text;
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

  v_url := 'https://omyyogfumrjoaweuawjn.supabase.co/functions/v1/discord-channel-index';
  IF v_feed_url IS NOT NULL THEN
    v_url := regexp_replace(v_feed_url, 'discord-sky-feed/?$', 'discord-channel-index');
    IF v_url = v_feed_url THEN
      v_url := 'https://omyyogfumrjoaweuawjn.supabase.co/functions/v1/discord-channel-index';
    END IF;
  END IF;

  UPDATE public.gpsl_discord_channel_index_settings
  SET edge_function_url = coalesce(nullif(btrim(edge_function_url), ''), v_url),
      invoke_key = coalesce(nullif(btrim(invoke_key), ''), v_feed_key),
      auto_poll_enabled = CASE
        WHEN coalesce(nullif(btrim(invoke_key), ''), v_feed_key) IS NOT NULL THEN true
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
    RAISE WARNING 'pg_cron not enabled';
    RETURN;
  END IF;

  FOR v_job IN
    SELECT jobid FROM cron.job WHERE jobname = 'gpsl-discord-channel-index'
  LOOP
    PERFORM cron.unschedule(v_job.jobid);
  END LOOP;

  PERFORM cron.schedule(
    'gpsl-discord-channel-index',
    '15 6 * * *',
    $$SELECT public.gpsl_discord_channel_index_request();$$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not schedule channel index cron: %', SQLERRM;
END;
$do$;

NOTIFY pgrst, 'reload schema';
