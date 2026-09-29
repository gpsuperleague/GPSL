-- =============================================================================
-- Discord club directory — short code · club name · owner tag · league (SL/CA/CB)
--
-- SETUP
-- -----
-- 1) Discord: your club directory channel
--    → Integrations → Webhooks → New Webhook → Copy URL
-- 2) Supabase → Edge Functions → Secrets:
--      DISCORD_CLUB_DIRECTORY_WEBHOOK_URL = that webhook URL
-- 3) Run THIS patch in SQL Editor (needs gpsl_discord_whos_who.sql applied)
-- 4) Redeploy: supabase functions deploy discord-sky-feed
-- 5) Admin → Discord News → "Publish Club Directory now"
--    (or: SELECT public.admin_discord_publish_club_directory(true);)
--
-- Daily cron (06:05 UTC) edits the SAME message(s) only when something changed.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gpsl_discord_club_directory_state (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  webhook_message_ids jsonb NOT NULL DEFAULT '[]'::jsonb,
  last_content_hash text,
  last_synced_at timestamptz,
  last_error text,
  last_action text,
  season_id bigint
);

INSERT INTO public.gpsl_discord_club_directory_state (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.gpsl_discord_club_directory_state ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gpsl_discord_club_directory_state_service ON public.gpsl_discord_club_directory_state;
CREATE POLICY gpsl_discord_club_directory_state_service
  ON public.gpsl_discord_club_directory_state
  FOR ALL TO service_role
  USING (true) WITH CHECK (true);

CREATE OR REPLACE FUNCTION public.gpsl_discord_club_directory_request_sync(
  p_force boolean DEFAULT false
)
RETURNS bigint
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
  FROM public.gpsl_discord_feed_settings s
  WHERE s.id = 1;

  IF v_url IS NULL OR v_key IS NULL THEN
    UPDATE public.gpsl_discord_club_directory_state
    SET last_error = 'missing edge_function_url or invoke_key in gpsl_discord_feed_settings',
        last_synced_at = now(),
        last_action = 'error'
    WHERE id = 1;
    RETURN NULL;
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
      'action', 'club_directory',
      'force', coalesce(p_force, false),
      'source', 'gpsl_discord_club_directory_request_sync'
    ),
    timeout_milliseconds := 30000
  );

  UPDATE public.gpsl_discord_club_directory_state
  SET last_synced_at = now(),
      last_error = NULL,
      last_action = 'requested'
  WHERE id = 1;

  RETURN v_req_id;
EXCEPTION
  WHEN undefined_function THEN
    UPDATE public.gpsl_discord_club_directory_state
    SET last_error = 'pg_net net.http_post missing — enable pg_net',
        last_synced_at = now(),
        last_action = 'error'
    WHERE id = 1;
    RETURN NULL;
  WHEN OTHERS THEN
    UPDATE public.gpsl_discord_club_directory_state
    SET last_error = left(SQLERRM, 500),
        last_synced_at = now(),
        last_action = 'error'
    WHERE id = 1;
    RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_club_directory_request_sync(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_club_directory_request_sync(boolean)
  TO postgres, service_role;

CREATE OR REPLACE FUNCTION public.admin_discord_publish_club_directory(
  p_force boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_req bigint;
BEGIN
  IF NOT public.is_gpsl_admin() THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  IF coalesce(p_force, true) THEN
    UPDATE public.gpsl_discord_club_directory_state
    SET last_content_hash = NULL
    WHERE id = 1;
  END IF;

  v_req := public.gpsl_discord_club_directory_request_sync(coalesce(p_force, true));

  RETURN jsonb_build_object(
    'ok', true,
    'request_id', v_req,
    'hint', 'Edge function will create or silently edit the club directory post within ~30s.'
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_discord_publish_club_directory(boolean)
  TO authenticated;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gpsl-discord-club-directory-daily') THEN
      PERFORM cron.unschedule('gpsl-discord-club-directory-daily');
    END IF;
    PERFORM cron.schedule(
      'gpsl-discord-club-directory-daily',
      '5 6 * * *',
      $job$SELECT public.gpsl_discord_club_directory_request_sync(false);$job$
    );
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'club directory cron schedule skipped: %', SQLERRM;
END;
$cron$;

NOTIFY pgrst, 'reload schema';
