-- =============================================================================
-- Friendlies top-2 prizes: hourly catch-up cron (2026-11-05)
--
-- Root cause tonight: September calendar locked at 19:00 UK, but
-- competition_run_month_lock_jobs / side_effects were never run — so
-- friendlies_prizes (wired into month lock) never fired. Prizes only paid
-- when admin ends the month (or a one-shot catch-up patch is applied).
--
-- Fix: schedule gpsl_friendlies_pay_locked_months_catchup every hour.
-- Idempotent (skips months that already have payout rows).
-- Also pays any currently locked month still missing prizes.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.gpsl_friendlies_prizes_cron_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_out jsonb;
BEGIN
  IF to_regprocedure('public.gpsl_friendlies_pay_locked_months_catchup(bigint)') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'catchup_fn_missing');
  END IF;

  v_out := public.gpsl_friendlies_pay_locked_months_catchup(NULL);
  RETURN coalesce(v_out, jsonb_build_object('ok', false, 'error', 'null_result'));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_friendlies_prizes_cron_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gpsl_friendlies_prizes_cron_tick() TO service_role;

COMMENT ON FUNCTION public.gpsl_friendlies_prizes_cron_tick() IS
  'Hourly: pay friendlies table prizes for any locked GPSL month still missing payouts.';

DO $cron$
BEGIN
  BEGIN
    PERFORM cron.unschedule('gpsl-friendlies-prizes-catchup');
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  PERFORM cron.schedule(
    'gpsl-friendlies-prizes-catchup',
    '20 * * * *',
    $q$SELECT public.gpsl_friendlies_prizes_cron_tick();$q$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not schedule friendlies prizes cron: %', SQLERRM;
END;
$cron$;

-- Pay anything still outstanding now
SELECT public.gpsl_friendlies_prizes_cron_tick() AS tick_now;

SELECT jobid, jobname, schedule, active, command
FROM cron.job
WHERE jobname = 'gpsl-friendlies-prizes-catchup';

SELECT p.gpsl_month, p.place, p.club_short_name, p.amount, p.created_at
FROM public.gpsl_friendlies_prize_payouts p
JOIN public.competition_seasons s ON s.id = p.season_id AND s.is_current
WHERE lower(p.gpsl_month) IN ('august', 'september')
ORDER BY p.gpsl_month, p.place;
