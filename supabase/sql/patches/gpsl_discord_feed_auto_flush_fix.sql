-- =============================================================================
-- Fix Discord feed auto-flush (pending rows never posting)
--
-- Cause: pg_net called the edge function with only a custom invoke key.
-- Supabase gateway still expects a real apikey (anon or service_role).
-- Manual Push worked because the browser sends your admin JWT + anon key.
--
-- Fix: send apikey + Authorization + x-discord-feed-key; record last flush status.
-- Recommended: paste the project service_role key as the Auto-post invoke key
-- (Project Settings → API → service_role). Edge already accepts it.
-- =============================================================================

ALTER TABLE public.gpsl_discord_feed_settings
  ADD COLUMN IF NOT EXISTS last_flush_at timestamptz,
  ADD COLUMN IF NOT EXISTS last_flush_request_id bigint,
  ADD COLUMN IF NOT EXISTS last_flush_error text;

CREATE OR REPLACE FUNCTION public.gpsl_discord_feed_request_flush()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, net
AS $function$
DECLARE
  v_url text;
  v_key text;
  v_enabled boolean;
  v_pending int;
  v_req_id bigint;
BEGIN
  SELECT s.edge_function_url, s.invoke_key, s.auto_flush_enabled
  INTO v_url, v_key, v_enabled
  FROM public.gpsl_discord_feed_settings s
  WHERE s.id = 1;

  IF NOT coalesce(v_enabled, false) THEN
    UPDATE public.gpsl_discord_feed_settings
    SET last_flush_error = 'auto_flush_enabled is false',
        last_flush_at = now()
    WHERE id = 1;
    RETURN;
  END IF;

  IF v_url IS NULL OR v_key IS NULL THEN
    UPDATE public.gpsl_discord_feed_settings
    SET last_flush_error = 'missing edge_function_url or invoke_key',
        last_flush_at = now()
    WHERE id = 1;
    RETURN;
  END IF;

  SELECT count(*)::int INTO v_pending
  FROM public.gpsl_discord_feed_queue
  WHERE status = 'pending';

  IF coalesce(v_pending, 0) < 1 THEN
    RETURN;
  END IF;

  -- Gateway needs a real apikey (anon/service_role). Custom invoke keys alone 401.
  -- Prefer saving service_role as invoke_key so both gateway + function auth succeed.
  v_req_id := net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', v_key,
      'Authorization', 'Bearer ' || v_key,
      'x-discord-feed-key', v_key
    ),
    body := jsonb_build_object('source', 'gpsl_discord_feed_request_flush'),
    timeout_milliseconds := 10000
  );

  UPDATE public.gpsl_discord_feed_settings
  SET last_flush_at = now(),
      last_flush_request_id = v_req_id,
      last_flush_error = NULL
  WHERE id = 1;
EXCEPTION
  WHEN undefined_function THEN
    UPDATE public.gpsl_discord_feed_settings
    SET last_flush_at = now(),
        last_flush_error = 'pg_net net.http_post missing — enable pg_net extension'
    WHERE id = 1;
  WHEN OTHERS THEN
    UPDATE public.gpsl_discord_feed_settings
    SET last_flush_at = now(),
        last_flush_error = left(SQLERRM, 500)
    WHERE id = 1;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_feed_request_flush() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_request_flush() TO postgres;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_feed_request_flush() TO service_role;

-- Admin can trigger + inspect
CREATE OR REPLACE FUNCTION public.admin_discord_feed_flush_now()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pending_before int;
  v_pending_after int;
  v_settings public.gpsl_discord_feed_settings%rowtype;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  SELECT count(*)::int INTO v_pending_before
  FROM public.gpsl_discord_feed_queue
  WHERE status = 'pending';

  PERFORM public.gpsl_discord_feed_request_flush();

  -- Give pg_net a moment for async completion when called interactively
  PERFORM pg_sleep(1.5);

  SELECT count(*)::int INTO v_pending_after
  FROM public.gpsl_discord_feed_queue
  WHERE status = 'pending';

  SELECT * INTO v_settings
  FROM public.gpsl_discord_feed_settings
  WHERE id = 1;

  RETURN jsonb_build_object(
    'ok', true,
    'pending_before', v_pending_before,
    'pending_after', v_pending_after,
    'last_flush_at', v_settings.last_flush_at,
    'last_flush_request_id', v_settings.last_flush_request_id,
    'last_flush_error', v_settings.last_flush_error,
    'hint', CASE
      WHEN v_pending_after > 0 AND v_settings.last_flush_error IS NOT NULL
        THEN v_settings.last_flush_error
      WHEN v_pending_after > 0
        THEN 'Still pending — save service_role key as Auto-post invoke key (Settings → API), enable pg_net, then try again'
      ELSE 'Queue drained (or empty)'
    END
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_discord_feed_flush_now() TO authenticated;

-- Faster retry while pending exists
DO $do$
DECLARE
  v_job record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RETURN;
  END IF;

  FOR v_job IN
    SELECT jobid FROM cron.job WHERE jobname = 'gpsl-discord-feed-flush'
  LOOP
    PERFORM cron.unschedule(v_job.jobid);
  END LOOP;

  PERFORM cron.schedule(
    'gpsl-discord-feed-flush',
    '* * * * *',
    $$SELECT public.gpsl_discord_feed_request_flush();$$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not reschedule discord feed cron: %', SQLERRM;
END;
$do$;

-- Kick once for current pending rows (e.g. Ryan Ponti)
SELECT public.gpsl_discord_feed_request_flush();

NOTIFY pgrst, 'reload schema';
