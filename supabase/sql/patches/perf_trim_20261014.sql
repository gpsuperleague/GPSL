-- =============================================================================
-- Performance trim (2026-10-14) — safe re-run.
--
-- 1. Indexes for the two most-scanned tables (competition_inbox, Player_Transfer_Bids)
-- 2. cron.job_run_details: delete history older than 3 days + daily cleanup job
--    (was 79 MB / ~400k rows — 40% of the database)
--
-- Optional afterwards (run on its own, not inside this script) to hand the
-- freed space back to disk:   VACUUM FULL cron.job_run_details;
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Indexes
-- ---------------------------------------------------------------------------
-- Season strip: message_type = 'draft_scheduled' AND dedupe_key LIKE 'draft_scheduled:%'
CREATE INDEX IF NOT EXISTS competition_inbox_type_dedupe_idx
  ON public.competition_inbox (message_type, dedupe_key text_pattern_ops);

-- Bids: by player, by bidder + status, pending direct offers, direct bid id
CREATE INDEX IF NOT EXISTS player_transfer_bids_player_idx
  ON public."Player_Transfer_Bids" (player_id);

CREATE INDEX IF NOT EXISTS player_transfer_bids_bidder_status_idx
  ON public."Player_Transfer_Bids" (bidder_club_id, status);

CREATE INDEX IF NOT EXISTS player_transfer_bids_pending_direct_idx
  ON public."Player_Transfer_Bids" (seller_club_id)
  WHERE is_direct = true AND listing_id IS NULL;

CREATE INDEX IF NOT EXISTS player_transfer_bids_direct_bid_idx
  ON public."Player_Transfer_Bids" (direct_bid_id)
  WHERE direct_bid_id IS NOT NULL;

ANALYZE public.competition_inbox;
ANALYZE public."Player_Transfer_Bids";

-- ---------------------------------------------------------------------------
-- 2. Cron run history: keep 3 days
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gpsl_cron_log_trim(p_keep_days int DEFAULT 3)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_deleted int := 0;
BEGIN
  IF to_regclass('cron.job_run_details') IS NULL THEN
    RETURN 0;
  END IF;
  DELETE FROM cron.job_run_details
  WHERE end_time < now() - make_interval(days => greatest(coalesce(p_keep_days, 3), 1));
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$function$;

REVOKE ALL ON FUNCTION public.gpsl_cron_log_trim(int) FROM PUBLIC, anon, authenticated;

SELECT public.gpsl_cron_log_trim(3) AS cron_rows_deleted_now;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'gpsl-cron-log-trim';
    PERFORM cron.schedule(
      'gpsl-cron-log-trim',
      '40 3 * * *',
      $job$SELECT public.gpsl_cron_log_trim(3);$job$
    );
  END IF;
END;
$cron$;

-- ---------------------------------------------------------------------------
-- Report
-- ---------------------------------------------------------------------------
SELECT 'cron.job_run_details rows' AS item, count(*)::text AS value FROM cron.job_run_details
UNION ALL
SELECT 'database size', pg_size_pretty(pg_database_size(current_database()))
UNION ALL
SELECT 'new indexes',
       string_agg(indexname, ', ' ORDER BY indexname)
FROM pg_indexes
WHERE indexname IN (
  'competition_inbox_type_dedupe_idx',
  'player_transfer_bids_player_idx',
  'player_transfer_bids_bidder_status_idx',
  'player_transfer_bids_pending_direct_idx',
  'player_transfer_bids_direct_bid_idx'
)
UNION ALL
SELECT 'cron cleanup job', coalesce(max(schedule), 'missing')
FROM cron.job WHERE jobname = 'gpsl-cron-log-trim';
