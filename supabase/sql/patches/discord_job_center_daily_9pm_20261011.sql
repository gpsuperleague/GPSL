-- =============================================================================
-- #gpsl-job-center: daily available-clubs post at 21:00 UK time
--
-- Before: the notifications tick (every 30 min) posted vacant clubs on its
-- first run each UK day (~00:15).
-- Now:
--   • gpsl_discord_job_center_post() builds the list (Super League,
--     Championship A, Championship B — clubs with no owner this season)
--   • gpsl_discord_job_center_daily_tick() posts it once per day at 21:00 UK
--     (cron at 20:00 and 21:00 UTC; only the run that lands on 21:xx UK posts,
--     so it stays at 9pm through BST/GMT changes)
--   • The notifications tick no longer posts Job Center (cron + admin button
--     go through a wrapper that marks today's job-center key as done)
--   • Admin "Post available clubs" button uses the same builder
-- Run AFTER discord_job_center_now_and_owner_departure_20261011.sql.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_discord_job_center_post(
  p_dedupe_key text,
  p_manual boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_season_id bigint;
  v_count int := 0;
  v_lines text;
  v_qid bigint;
BEGIN
  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'No current season');
  END IF;

  SELECT count(*)::int,
         string_agg(
           format('• **%s** (%s)',
                  coalesce(nullif(btrim(c."Club"), ''), c."ShortName"),
                  public.gpsl_discord_division_label(ccs.division)),
           E'\n'
           ORDER BY
             CASE lower(ccs.division)
               WHEN 'superleague' THEN 1
               WHEN 'championship_a' THEN 2
               WHEN 'championship_b' THEN 3
               ELSE 9
             END,
             c."Club"
         )
  INTO v_count, v_lines
  FROM public.competition_club_seasons ccs
  JOIN public."Clubs" c ON c."ShortName" = ccs.club_short_name
  WHERE ccs.season_id = v_season_id
    AND lower(ccs.division) IN ('superleague', 'championship_a', 'championship_b')
    AND c.owner_id IS NULL
    AND c."ShortName" IS DISTINCT FROM 'FOREIGN';

  IF coalesce(v_count, 0) = 0 THEN
    RETURN jsonb_build_object('ok', true, 'posted', false, 'vacant', 0);
  END IF;

  v_qid := public.gpsl_discord_feed_enqueue_job_center(
    'job_center',
    format('🏚️ JOB CENTER — %s club(s) available', v_count),
    left(v_lines || E'\n\nInterested? Ask an admin in Discord to take one over.', 3800),
    10038562,
    p_dedupe_key,
    jsonb_build_object('kind', 'job_center', 'count', v_count, 'season_id', v_season_id,
                       'manual', coalesce(p_manual, false))
  );

  BEGIN
    PERFORM public.gpsl_discord_feed_request_flush();
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  RETURN jsonb_build_object('ok', true, 'posted', v_qid IS NOT NULL, 'vacant', v_count, 'queue_id', v_qid);
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_job_center_post(text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_job_center_post(text, boolean) TO service_role;

-- Daily 21:00 UK post (dedupe per UK date)
CREATE OR REPLACE FUNCTION public.gpsl_discord_job_center_daily_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_uk timestamp := now() AT TIME ZONE 'Europe/London';
BEGIN
  IF extract(hour FROM v_uk) <> 21 THEN
    RETURN jsonb_build_object('ok', true, 'posted', false, 'reason', 'not 21:00 UK');
  END IF;
  RETURN public.gpsl_discord_job_center_post(
    'job_center_daily:' || to_char(v_uk::date, 'YYYY-MM-DD'),
    false
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_job_center_daily_tick() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_job_center_daily_tick() TO service_role;

-- Admin button: post now
CREATE OR REPLACE FUNCTION public.admin_discord_job_center_post_now()
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
  RETURN public.gpsl_discord_job_center_post(
    'job_center_now:' || floor(extract(epoch FROM now()))::bigint::text,
    true
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_discord_job_center_post_now() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_discord_job_center_post_now() TO authenticated, service_role;

-- Notifications tick without its own Job Center post
CREATE OR REPLACE FUNCTION public.gpsl_discord_notifications_tick_no_job_center()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  UPDATE public.gpsl_discord_notifications_state
  SET last_vacant_key = 'job_center:' || to_char((now() AT TIME ZONE 'Europe/London')::date, 'YYYY-MM-DD')
  WHERE id = 1;
  RETURN public.gpsl_discord_notifications_tick();
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_discord_notifications_tick_no_job_center() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.gpsl_discord_notifications_tick_no_job_center() TO service_role;

CREATE OR REPLACE FUNCTION public.admin_discord_notifications_tick_now()
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
  RETURN public.gpsl_discord_notifications_tick_no_job_center();
END;
$function$;

GRANT EXECUTE ON FUNCTION public.admin_discord_notifications_tick_now() TO authenticated;

-- Cron: notifications tick via wrapper; Job Center at 20:00 + 21:00 UTC
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('gpsl-discord-notifications-tick');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'gpsl-discord-notifications-tick',
      '15,45 * * * *',
      $$SELECT public.gpsl_discord_notifications_tick_no_job_center();$$
    );

    BEGIN
      PERFORM cron.unschedule('gpsl-discord-job-center-daily');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
    PERFORM cron.schedule(
      'gpsl-discord-job-center-daily',
      '0 20,21 * * *',
      $$SELECT public.gpsl_discord_job_center_daily_tick();$$
    );
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron schedule skipped: %', SQLERRM;
END;
$cron$;

NOTIFY pgrst, 'reload schema';

-- Report: cron jobs now scheduled for these
SELECT jobname, schedule, command
FROM cron.job
WHERE jobname IN ('gpsl-discord-notifications-tick', 'gpsl-discord-job-center-daily')
ORDER BY jobname;
