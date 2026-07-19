-- =============================================================================
-- Discord friendlies — auto-poll cron (pg_cron + pg_net)
--
-- Run AFTER discord_friendlies_gate.sql and after deploying
-- discord-friendlies-ingest with secrets set.
--
-- Then configure once (Admin SQL or here):
--   SELECT public.admin_discord_friendlies_set_auto(
--     'https://<project-ref>.supabase.co/functions/v1/discord-friendlies-ingest',
--     '<DISCORD_FRIENDLIES_INVOKE_KEY or service_role JWT>',
--     true
--   );
--
-- Safe re-run.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpsl_discord_friendlies_settings (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  edge_function_url text,
  invoke_key text,
  auto_poll_enabled boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.gpsl_discord_friendlies_settings (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.gpsl_discord_friendlies_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_discord_friendlies_settings_admin ON public.gpsl_discord_friendlies_settings;
CREATE POLICY gpsl_discord_friendlies_settings_admin
  ON public.gpsl_discord_friendlies_settings
  FOR ALL TO authenticated
  USING (public.is_gpsl_admin())
  WITH CHECK (public.is_gpsl_admin());

GRANT SELECT, UPDATE ON public.gpsl_discord_friendlies_settings TO authenticated;
GRANT ALL ON public.gpsl_discord_friendlies_settings TO service_role;

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
  v_url text := nullif(btrim(coalesce(p_edge_function_url, '')), '');
  v_key text := nullif(btrim(coalesce(p_invoke_key, '')), '');
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  INSERT INTO public.gpsl_discord_friendlies_settings (id)
  VALUES (1)
  ON CONFLICT (id) DO NOTHING;

  UPDATE public.gpsl_discord_friendlies_settings
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
      FROM public.gpsl_discord_friendlies_settings WHERE id = 1
    ),
    'has_key', (
      SELECT nullif(btrim(coalesce(invoke_key, '')), '') IS NOT NULL
      FROM public.gpsl_discord_friendlies_settings WHERE id = 1
    )
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_discord_friendlies_set_auto(text, text, boolean)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.gpsl_discord_friendlies_request_poll()
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
  FROM public.gpsl_discord_friendlies_settings s
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
    timeout_milliseconds := 15000
  );
EXCEPTION
  WHEN undefined_function THEN
    RAISE WARNING 'gpsl_discord_friendlies_request_poll: pg_net missing';
  WHEN OTHERS THEN
    RAISE WARNING 'gpsl_discord_friendlies_request_poll failed: %', SQLERRM;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_friendlies_request_poll() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_friendlies_request_poll() TO postgres;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_friendlies_request_poll() TO service_role;

DO $do$
DECLARE
  v_job record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE WARNING 'pg_cron not enabled — use Admin → Discord Friendlies → Poll now';
    RETURN;
  END IF;

  FOR v_job IN
    SELECT jobid FROM cron.job WHERE jobname = 'gpsl-discord-friendlies-poll'
  LOOP
    PERFORM cron.unschedule(v_job.jobid);
  END LOOP;

  PERFORM cron.schedule(
    'gpsl-discord-friendlies-poll',
    '*/2 * * * *',
    $$SELECT public.gpsl_discord_friendlies_request_poll();$$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not schedule friendlies cron: %', SQLERRM;
END;
$do$;
