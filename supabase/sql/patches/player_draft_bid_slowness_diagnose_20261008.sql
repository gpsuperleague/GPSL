-- =============================================================================
-- Diagnose: manual draft bids slow while the auto-bid tick runs (read-only)
-- One result row.
-- =============================================================================

SELECT
  (SELECT command FROM cron.job WHERE jobname = 'gpsl-draft-autobid')
                                                   AS autobid_cron_command,
  to_regprocedure('public.player_draft_autobid_tick_proc()') IS NOT NULL
                                                   AS scale_patch_proc_installed,
  to_regclass('public.player_transfer_bids_draft_player_time_idx') IS NOT NULL
                                                   AS scale_patch_index_installed,
  (SELECT string_agg(
            to_char(d.start_time AT TIME ZONE 'Europe/London', 'HH24:MI')
            || ' ' || d.status || ' '
            || round(extract(epoch FROM (d.end_time - d.start_time)))::text || 's',
            ' | ' ORDER BY d.start_time DESC)
     FROM (SELECT * FROM cron.job_run_details r
            WHERE r.jobid = (SELECT jobid FROM cron.job WHERE jobname = 'gpsl-draft-autobid')
            ORDER BY r.start_time DESC LIMIT 8) d)
                                                   AS autobid_last_runs,
  (SELECT count(*) FROM public.player_draft_autobid_plans pl
    WHERE pl.status IN ('scheduled', 'live') AND pl.enabled)
                                                   AS live_plans,
  (SELECT count(*) FROM pg_stat_activity a
    WHERE a.wait_event_type = 'Lock' AND a.datname = current_database())
                                                   AS queries_waiting_on_locks_now,
  (SELECT string_agg(left(regexp_replace(a.query, '\s+', ' ', 'g'), 120)
            || ' (' || round(extract(epoch FROM (now() - a.query_start)))::text || 's)', ' | ')
     FROM pg_stat_activity a
    WHERE a.state = 'active' AND a.pid <> pg_backend_pid()
      AND a.datname = current_database()
      AND now() - a.query_start > interval '2 seconds')
                                                   AS long_running_queries_now,
  (SELECT count(*) FROM public."Player_Transfer_Bids" b
    WHERE b.is_direct AND b.seller_club_id IS NULL
      AND b.bid_time > now() - interval '10 minutes')
                                                   AS draft_bids_last_10_min;
