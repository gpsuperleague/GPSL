-- =============================================================================
-- Why didn't the special auctions post to the Discord calendar channel?
-- Read-only. Run the whole file — the result is ONE table of checks.
-- =============================================================================

WITH checks AS (
  SELECT 1 AS n, 'trigger on special_auctions' AS check_name,
         coalesce((
           SELECT string_agg(t.tgname || ' → ' || p.proname
                             || CASE WHEN t.tgenabled = 'D' THEN ' (DISABLED)' ELSE '' END, '; ')
           FROM pg_trigger t
           JOIN pg_proc p ON p.oid = t.tgfoid
           WHERE t.tgrelid = 'public.special_auctions'::regclass
             AND NOT t.tgisinternal
             AND p.proname ILIKE '%discord%'
         ), 'MISSING') AS result
  UNION ALL
  SELECT 2, 'enqueue_notification function',
         CASE WHEN to_regprocedure('public.gpsl_discord_feed_enqueue_notification(text,text,text,integer,text,jsonb)') IS NULL
              THEN 'MISSING' ELSE 'ok' END
  UNION ALL
  SELECT 3, 'queue rows for auctions 11/12',
         coalesce((
           SELECT string_agg(
                    format('#%s %s [%s] %s %s', q.id, q.dedupe_key, q.status,
                           to_char(q.created_at AT TIME ZONE 'Europe/London', 'DD Mon HH24:MI'),
                           coalesce(left(q.last_error, 120), '')),
                    ' | ' ORDER BY q.id)
           FROM public.gpsl_discord_feed_queue q
           WHERE q.dedupe_key LIKE 'special_auction:11:%'
              OR q.dedupe_key LIKE 'special_auction:12:%'
         ), 'NONE — trigger never queued them')
  UNION ALL
  SELECT 4, 'latest calendar-channel posts',
         coalesce((
           SELECT string_agg(format('#%s %s [%s] %s', x.id, left(x.headline, 50), x.status,
                                    to_char(x.created_at AT TIME ZONE 'Europe/London', 'DD Mon HH24:MI')),
                             ' | ' ORDER BY x.id DESC)
           FROM (
             SELECT q.*
             FROM public.gpsl_discord_feed_queue q
             WHERE q.metadata->>'channel' = 'notifications'
             ORDER BY q.id DESC
             LIMIT 5
           ) x
         ), 'none')
  UNION ALL
  SELECT 5, 'queue backlog (pending / error)',
         (SELECT format('%s pending, %s error',
                        count(*) FILTER (WHERE status = 'pending'),
                        count(*) FILTER (WHERE status = 'error'))
          FROM public.gpsl_discord_feed_queue)
)
SELECT n, check_name, result FROM checks ORDER BY n;
