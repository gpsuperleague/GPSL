-- =============================================================================
-- Performance review (READ-ONLY) — run in Supabase SQL editor, copy the result grid.
-- Sections: size, biggest tables, cron load, slowest queries, connections,
-- cache hit, seq-scan hot spots, unused indexes, dead rows, log tables.
-- Nothing is changed (only a session temp table is used for the report).
-- =============================================================================

CREATE TEMP TABLE IF NOT EXISTS _perf_report (
  section text,
  item    text,
  value   text,
  sort    numeric
);
TRUNCATE _perf_report;

DO $perf$
DECLARE
  r record;
BEGIN
  -- 1. Database size
  INSERT INTO _perf_report
  SELECT '01 database size', current_database(),
         pg_size_pretty(pg_database_size(current_database())), 0;

  -- 2. Biggest tables (all schemas, incl. cron / net / auth / storage)
  INSERT INTO _perf_report
  SELECT '02 biggest tables',
         n.nspname || '.' || c.relname,
         pg_size_pretty(pg_total_relation_size(c.oid))
           || ' · ~' || coalesce(c.reltuples::bigint, 0) || ' rows',
         -pg_total_relation_size(c.oid)
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p', 'm')
    AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  ORDER BY pg_total_relation_size(c.oid) DESC
  LIMIT 20;

  -- 3. Cron load, last 24h
  IF to_regclass('cron.job_run_details') IS NOT NULL THEN
    INSERT INTO _perf_report
    SELECT '03 cron last 24h',
           j.jobname || '  [' || j.schedule || ']' || CASE WHEN j.active THEN '' ELSE ' (inactive)' END,
           coalesce(s.runs, 0) || ' runs · avg '
             || coalesce(round(s.avg_ms)::text, '-') || ' ms · max '
             || coalesce(round(s.max_ms)::text, '-') || ' ms · total '
             || coalesce(round(s.total_ms / 1000.0)::text, '0') || ' s · failed '
             || coalesce(s.failed, 0),
           -coalesce(s.total_ms, 0)
    FROM cron.job j
    LEFT JOIN LATERAL (
      SELECT count(*) AS runs,
             avg(extract(epoch FROM (d.end_time - d.start_time)) * 1000) AS avg_ms,
             max(extract(epoch FROM (d.end_time - d.start_time)) * 1000) AS max_ms,
             sum(extract(epoch FROM (d.end_time - d.start_time)) * 1000) AS total_ms,
             count(*) FILTER (WHERE d.status <> 'succeeded') AS failed
      FROM cron.job_run_details d
      WHERE d.jobid = j.jobid
        AND d.start_time > now() - interval '24 hours'
    ) s ON true;

    INSERT INTO _perf_report
    SELECT '03 cron last 24h', 'TOTAL (all jobs)',
           count(*) || ' runs · ' || round(coalesce(sum(extract(epoch FROM (end_time - start_time))), 0)) || ' s busy',
           -1e15
    FROM cron.job_run_details
    WHERE start_time > now() - interval '24 hours';
  END IF;

  -- 4. Slowest queries (needs pg_stat_statements)
  BEGIN
    FOR r IN EXECUTE $q$
      SELECT left(regexp_replace(query, '\s+', ' ', 'g'), 140) AS q,
             calls,
             round(total_exec_time::numeric) AS total_ms,
             round(mean_exec_time::numeric, 1) AS mean_ms
      FROM extensions.pg_stat_statements
      WHERE query NOT ILIKE '%pg_stat_statements%'
      ORDER BY total_exec_time DESC
      LIMIT 25
    $q$
    LOOP
      INSERT INTO _perf_report VALUES (
        '04 top queries by total time', r.q,
        r.calls || ' calls · total ' || round(r.total_ms / 1000.0) || ' s · mean ' || r.mean_ms || ' ms',
        -r.total_ms
      );
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO _perf_report VALUES ('04 top queries by total time', 'pg_stat_statements unavailable', SQLERRM, 0);
  END;

  -- 5. Connections
  INSERT INTO _perf_report
  SELECT '05 connections',
         coalesce(nullif(application_name, ''), '(none)') || ' · ' || coalesce(state, '?'),
         count(*)::text,
         -count(*)
  FROM pg_stat_activity
  WHERE datname = current_database()
  GROUP BY 1, 2;

  INSERT INTO _perf_report
  SELECT '05 connections', 'max_connections', current_setting('max_connections'), 1e9;

  -- 6. Cache hit ratios (want > 99%)
  INSERT INTO _perf_report
  SELECT '06 cache hit', 'table hit %',
         round(100.0 * sum(heap_blks_hit) / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0), 2)::text, 0
  FROM pg_statio_user_tables;
  INSERT INTO _perf_report
  SELECT '06 cache hit', 'index hit %',
         round(100.0 * sum(idx_blks_hit) / nullif(sum(idx_blks_hit) + sum(idx_blks_read), 0), 2)::text, 1
  FROM pg_statio_user_indexes;

  -- 7. Seq-scan hot spots (big tables read in full a lot → missing index)
  INSERT INTO _perf_report
  SELECT '07 seq-scan hot spots',
         schemaname || '.' || relname,
         seq_scan || ' seq scans · ' || seq_tup_read || ' rows read · idx scans ' || coalesce(idx_scan, 0)
           || ' · live ' || n_live_tup,
         -seq_tup_read
  FROM pg_stat_user_tables
  WHERE n_live_tup > 1000
  ORDER BY seq_tup_read DESC
  LIMIT 15;

  -- 8. Unused indexes (> 1 MB, never scanned since stats reset)
  INSERT INTO _perf_report
  SELECT '08 unused indexes',
         s.schemaname || '.' || s.indexrelname || ' on ' || s.relname,
         pg_size_pretty(pg_relation_size(s.indexrelid)),
         -pg_relation_size(s.indexrelid)
  FROM pg_stat_user_indexes s
  JOIN pg_index i ON i.indexrelid = s.indexrelid
  WHERE s.idx_scan = 0
    AND NOT i.indisunique
    AND NOT i.indisprimary
    AND pg_relation_size(s.indexrelid) > 1024 * 1024
  ORDER BY pg_relation_size(s.indexrelid) DESC
  LIMIT 15;

  -- 9. Dead rows (bloat waiting for vacuum)
  INSERT INTO _perf_report
  SELECT '09 dead rows',
         schemaname || '.' || relname,
         n_dead_tup || ' dead / ' || n_live_tup || ' live · last autovacuum '
           || coalesce(to_char(last_autovacuum, 'YYYY-MM-DD HH24:MI'), 'never'),
         -n_dead_tup
  FROM pg_stat_all_tables
  WHERE n_dead_tup > 10000
  ORDER BY n_dead_tup DESC
  LIMIT 15;

  -- 10. Log tables that grow forever
  IF to_regclass('cron.job_run_details') IS NOT NULL THEN
    INSERT INTO _perf_report
    SELECT '10 log tables', 'cron.job_run_details',
           count(*) || ' rows · oldest ' || coalesce(to_char(min(start_time), 'YYYY-MM-DD'), '-')
             || ' · ' || pg_size_pretty(pg_total_relation_size('cron.job_run_details')),
           0
    FROM cron.job_run_details;
  END IF;
  IF to_regclass('net._http_response') IS NOT NULL THEN
    INSERT INTO _perf_report
    SELECT '10 log tables', 'net._http_response',
           count(*) || ' rows · ' || pg_size_pretty(pg_total_relation_size('net._http_response')),
           1
    FROM net._http_response;
  END IF;
  IF to_regclass('net.http_request_queue') IS NOT NULL THEN
    INSERT INTO _perf_report
    SELECT '10 log tables', 'net.http_request_queue (pending)',
           count(*)::text, 2
    FROM net.http_request_queue;
  END IF;

  -- 11. Stats window (how far back the counters go)
  INSERT INTO _perf_report
  SELECT '11 stats since', 'pg_stat_database reset',
         coalesce(to_char(stats_reset, 'YYYY-MM-DD HH24:MI'), 'never reset'), 0
  FROM pg_stat_database WHERE datname = current_database();
END;
$perf$;

SELECT section, item, value
FROM _perf_report
ORDER BY section, sort, item;
