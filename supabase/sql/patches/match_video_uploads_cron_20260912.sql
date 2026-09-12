-- =============================================================================
-- Match videos — auto-poll cron (pg_cron + pg_net) — no always-on PC needed
--
-- Run AFTER match_video_uploads_20260912.sql and AFTER deploying
-- discord-match-videos-ingest with Edge secrets:
--   DISCORD_BOT_TOKEN, DISCORD_GUILD_ID, DISCORD_MATCH_VIDEOS_CATEGORY_ID
--
-- Copies invoke URL/key from Discord Friendlies or News settings when possible.
-- Enable from Admin → Match videos → Save auto-poll.
-- Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpsl_discord_match_videos_settings (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  edge_function_url text,
  invoke_key text,
  auto_poll_enabled boolean NOT NULL DEFAULT false,
  channel_cursors jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.gpsl_discord_match_videos_settings (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.gpsl_discord_match_videos_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_discord_match_videos_settings_admin
  ON public.gpsl_discord_match_videos_settings;
CREATE POLICY gpsl_discord_match_videos_settings_admin
  ON public.gpsl_discord_match_videos_settings
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT, UPDATE ON public.gpsl_discord_match_videos_settings TO authenticated;
GRANT ALL ON public.gpsl_discord_match_videos_settings TO service_role;

CREATE OR REPLACE FUNCTION public.admin_discord_match_videos_get_auto()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_url text;
  v_enabled boolean;
  v_key text;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_only');
  END IF;

  SELECT s.edge_function_url, s.auto_poll_enabled, s.invoke_key
  INTO v_url, v_enabled, v_key
  FROM public.gpsl_discord_match_videos_settings s
  WHERE s.id = 1;

  RETURN jsonb_build_object(
    'ok', true,
    'edge_function_url', v_url,
    'auto_poll_enabled', coalesce(v_enabled, false),
    'has_key', nullif(btrim(coalesce(v_key, '')), '') IS NOT NULL
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_discord_match_videos_set_auto(
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

  INSERT INTO public.gpsl_discord_match_videos_settings (id)
  VALUES (1)
  ON CONFLICT (id) DO NOTHING;

  UPDATE public.gpsl_discord_match_videos_settings
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
      FROM public.gpsl_discord_match_videos_settings WHERE id = 1
    ),
    'has_key', (
      SELECT nullif(btrim(coalesce(invoke_key, '')), '') IS NOT NULL
      FROM public.gpsl_discord_match_videos_settings WHERE id = 1
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_discord_match_videos_get_auto() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_discord_match_videos_set_auto(text, text, boolean)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.gpsl_discord_match_videos_request_poll()
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
  FROM public.gpsl_discord_match_videos_settings s
  WHERE s.id = 1;

  IF NOT coalesce(v_enabled, false) THEN
    RETURN;
  END IF;
  IF v_url IS NULL OR v_key IS NULL THEN
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body := jsonb_build_object('limit', 40),
    timeout_milliseconds := 55000
  );
EXCEPTION
  WHEN undefined_function THEN
    RAISE WARNING 'gpsl_discord_match_videos_request_poll: pg_net missing';
  WHEN OTHERS THEN
    RAISE WARNING 'gpsl_discord_match_videos_request_poll failed: %', SQLERRM;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_match_videos_request_poll() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_match_videos_request_poll() TO postgres;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_match_videos_request_poll() TO service_role;

-- Bootstrap URL + key from friendlies / news settings
DO $boot$
DECLARE
  v_feed_url text;
  v_feed_key text;
  v_fr_url text;
  v_fr_key text;
  v_cur_url text;
  v_cur_key text;
  v_mv_url text;
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

  BEGIN
    SELECT nullif(btrim(edge_function_url), ''), nullif(btrim(invoke_key), '')
    INTO v_fr_url, v_fr_key
    FROM public.gpsl_discord_friendlies_settings
    WHERE id = 1;
  EXCEPTION WHEN undefined_table THEN
    v_fr_url := NULL;
    v_fr_key := NULL;
  END;

  SELECT nullif(btrim(edge_function_url), ''), nullif(btrim(invoke_key), '')
  INTO v_cur_url, v_cur_key
  FROM public.gpsl_discord_match_videos_settings
  WHERE id = 1;

  v_mv_url := coalesce(
    v_cur_url,
    CASE
      WHEN v_fr_url IS NOT NULL THEN
        regexp_replace(v_fr_url, 'discord-friendlies-ingest/?$', 'discord-match-videos-ingest')
      WHEN v_feed_url IS NOT NULL THEN
        regexp_replace(v_feed_url, 'discord-sky-feed/?$', 'discord-match-videos-ingest')
      ELSE
        'https://omyyogfumrjoaweuawjn.supabase.co/functions/v1/discord-match-videos-ingest'
    END
  );

  UPDATE public.gpsl_discord_match_videos_settings
  SET edge_function_url = v_mv_url,
      invoke_key = coalesce(v_cur_key, v_fr_key, v_feed_key),
      auto_poll_enabled = CASE
        WHEN coalesce(v_cur_key, v_fr_key, v_feed_key) IS NOT NULL THEN true
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
    RAISE WARNING 'pg_cron not enabled — use Admin → Match videos → Poll now';
    RETURN;
  END IF;

  FOR v_job IN
    SELECT jobid FROM cron.job WHERE jobname = 'gpsl-discord-match-videos-poll'
  LOOP
    PERFORM cron.unschedule(v_job.jobid);
  END LOOP;

  PERFORM cron.schedule(
    'gpsl-discord-match-videos-poll',
    '*/2 * * * *',
    $$SELECT public.gpsl_discord_match_videos_request_poll();$$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not schedule match-videos cron: %', SQLERRM;
END;
$do$;
