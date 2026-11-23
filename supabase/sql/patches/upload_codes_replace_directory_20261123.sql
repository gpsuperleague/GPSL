-- The upload-codes club list replaces the old GPSL Club Directory post.
-- Stop the directory job from posting that list back into the channel.
-- Owner changes refresh the upload-codes posts instead.

CREATE OR REPLACE FUNCTION public.gpsl_discord_club_directory_request_sync(
  p_force boolean DEFAULT false
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_sync jsonb;
BEGIN
  UPDATE public.gpsl_discord_club_directory_state
  SET webhook_message_ids = '[]'::jsonb,
      last_content_hash = NULL,
      last_synced_at = now(),
      last_error = NULL,
      last_action = 'replaced_by_upload_codes'
  WHERE id = 1;

  IF to_regprocedure('public.gpsl_discord_match_videos_request_sync_codes()') IS NULL THEN
    RETURN NULL;
  END IF;

  v_sync := public.gpsl_discord_match_videos_request_sync_codes();
  RETURN NULLIF(v_sync->>'request_id', '')::bigint;
END;
$function$;

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
  IF NOT public.is_gpsl_admin()
     AND current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  v_req := public.gpsl_discord_club_directory_request_sync(coalesce(p_force, true));

  RETURN jsonb_build_object(
    'ok', true,
    'request_id', v_req,
    'hint', 'Upload-codes club list is refreshed. The old directory post is not reposted.'
  );
END;
$function$;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gpsl-discord-club-directory-daily') THEN
      PERFORM cron.unschedule('gpsl-discord-club-directory-daily');
    END IF;
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'directory cron unschedule skipped: %', SQLERRM;
END;
$cron$;
