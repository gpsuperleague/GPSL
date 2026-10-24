-- =============================================================================
-- Match videos: daily cup-codes refresh in Discord #upload-codes at 21:00 UK
-- Plus helper to invoke sync_codes now (same Edge Function).
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_discord_match_videos_request_sync_codes()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, net
AS $function$
DECLARE
  v_url text;
  v_key text;
  v_req_id bigint;
BEGIN
  SELECT s.edge_function_url, s.invoke_key
  INTO v_url, v_key
  FROM public.gpsl_discord_match_videos_settings s
  WHERE s.id = 1;

  IF nullif(btrim(coalesce(v_url, '')), '') IS NULL
     OR nullif(btrim(coalesce(v_key, '')), '') IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'match_videos edge URL or invoke key missing — enable Auto-poll once in Admin → Match videos'
    );
  END IF;

  SELECT net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body := jsonb_build_object('mode', 'sync_codes'),
    timeout_milliseconds := 55000
  )
  INTO v_req_id;

  RETURN jsonb_build_object('ok', true, 'request_id', v_req_id);
EXCEPTION
  WHEN undefined_function THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'pg_net missing');
  WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'reason', SQLERRM);
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_match_videos_request_sync_codes() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_match_videos_request_sync_codes()
  TO postgres, service_role;

-- Cron tick: only fire when UK clock is 21:00 hour (handles BST/GMT)
CREATE OR REPLACE FUNCTION public.gpsl_discord_match_videos_cup_codes_daily_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uk timestamptz := now() AT TIME ZONE 'Europe/London';
BEGIN
  IF extract(hour FROM v_uk) <> 21 THEN
    RETURN jsonb_build_object('ok', true, 'posted', false, 'reason', 'not 21:00 UK');
  END IF;
  RETURN public.gpsl_discord_match_videos_request_sync_codes()
    || jsonb_build_object('posted', true, 'uk_hour', 21);
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_match_videos_cup_codes_daily_tick() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_match_videos_cup_codes_daily_tick()
  TO postgres, service_role;

-- Admin: run now
CREATE OR REPLACE FUNCTION public.admin_discord_match_videos_sync_cup_codes_now()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;
  RETURN public.gpsl_discord_match_videos_request_sync_codes();
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_discord_match_videos_sync_cup_codes_now() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_discord_match_videos_sync_cup_codes_now()
  TO authenticated, service_role;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('gpsl-match-video-cup-codes-daily');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    -- 20:00 and 21:00 UTC cover 21:00 UK in BST and GMT; tick filters on UK hour
    PERFORM cron.schedule(
      'gpsl-match-video-cup-codes-daily',
      '0 20,21 * * *',
      $$SELECT public.gpsl_discord_match_videos_cup_codes_daily_tick();$$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron schedule skipped: %', SQLERRM;
END;
$cron$;

NOTIFY pgrst, 'reload schema';

SELECT jobname, schedule, command
FROM cron.job
WHERE jobname = 'gpsl-match-video-cup-codes-daily';

-- Fire one sync now
SELECT public.gpsl_discord_match_videos_request_sync_codes() AS sync_now;
