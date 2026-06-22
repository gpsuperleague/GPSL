-- =============================================================================
-- Check draft secret random finish time (read-only diagnostic)
-- Run in Supabase SQL Editor. Reads global_settings directly (not the public view).
-- =============================================================================
--
-- Random finish is set when draft is enabled in Admin → Transfer window & engine.
-- Window: Day 2 @ 18:50:00–18:59:58 UK after draft_auction_start_time (Day 1 @ 19:00 UK).
-- transferengine_settle_draft_auctions() runs after draft_random_finish_time.

SELECT
  g.id,
  g.draft_auction_enabled,
  g.draft_auction_start_time,
  g.draft_auction_start_time AT TIME ZONE 'Europe/London' AS draft_start_uk,
  g.draft_random_finish_time,
  g.draft_random_finish_time AT TIME ZONE 'Europe/London' AS random_finish_uk,
  g.updated_at,
  now() AS server_now,
  now() AT TIME ZONE 'Europe/London' AS server_now_uk,
  CASE
    WHEN NOT COALESCE(g.draft_auction_enabled, false) THEN 'draft disabled'
    WHEN g.draft_auction_start_time IS NULL THEN 'no start time'
    WHEN g.draft_random_finish_time IS NULL THEN 'no random finish set'
    WHEN now() < g.draft_auction_start_time THEN 'before draft start'
    WHEN now() < g.draft_random_finish_time THEN 'bidding open (before secret finish)'
    ELSE 'secret finish passed — settlement should run'
  END AS draft_phase,
  g.draft_random_finish_time IS NOT NULL AND now() >= g.draft_random_finish_time AS finish_due,
  (
    COALESCE(g.draft_auction_enabled, false)
    AND g.draft_auction_start_time IS NOT NULL
    AND g.draft_random_finish_time IS NOT NULL
    AND now() >= g.draft_auction_start_time
    AND now() < g.draft_random_finish_time
  ) AS draft_bidding_open,
  EXTRACT(EPOCH FROM (g.draft_random_finish_time - now()))::int AS seconds_until_finish
FROM public.global_settings g
WHERE g.id = 1;

-- Active draft listings waiting on the timer
SELECT
  l.id AS listing_id,
  l.player_id,
  p."Name" AS player_name,
  l.status,
  l.current_highest_bid,
  l.current_highest_bidder,
  l.end_time,
  l.created_at
FROM public."Player_Transfer_Listings" l
LEFT JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
WHERE l.listing_type = 'draft'
  AND l.status = 'Active'
ORDER BY l.id;

-- Why draft may not have settled yet (money/players wait for 7pm transfer list)
SELECT
  g.draft_random_finish_time IS NOT NULL AND now() >= g.draft_random_finish_time AS secret_finish_passed,
  public.transferengine_standard_listings_block_draft_settlement(
    now(),
    g.draft_random_finish_time
  ) AS blocked_by_active_7pm_transfer_list,
  (
    SELECT count(*)::int
    FROM public."Player_Transfer_Listings" l
    WHERE l.status = 'Active'
      AND l.listing_type IS DISTINCT FROM 'draft'
      AND l.end_time > now()
      AND public.gpsl_timestamptz_uk_date(
            COALESCE(l.initial_end_time, l.end_time)
          ) = public.gpsl_timestamptz_uk_date(g.draft_random_finish_time)
      AND (
        COALESCE(l.was_extended, false)
        OR EXTRACT(
              HOUR FROM (
                COALESCE(l.initial_end_time, l.end_time)
                  AT TIME ZONE 'Europe/London'
              )
            )::int = 19
      )
  ) AS blocking_7pm_or_extended_listings,
  (
    SELECT count(*)::int
    FROM public."Player_Transfer_Listings" l
    WHERE l.listing_type = 'draft'
      AND l.status = 'Active'
  ) AS active_draft_listings_pending_settlement,
  (
    SELECT coalesce(draft_bidding_open, false)
    FROM public.global_settings_public
    WHERE id = 1
  ) AS draft_bidding_open_now,
  CASE
    WHEN NOT COALESCE(g.draft_auction_enabled, false) THEN 'draft disabled'
    WHEN g.draft_random_finish_time IS NULL THEN 'no random finish'
    WHEN now() < g.draft_random_finish_time THEN 'before secret finish'
    WHEN public.transferengine_standard_listings_block_draft_settlement(
      now(),
      g.draft_random_finish_time
    ) THEN 'waiting on 7pm transfer list (or extension)'
    ELSE 'ready — run transferengine_run()'
  END AS settlement_status
FROM public.global_settings g
WHERE g.id = 1;

-- Exact rows that block draft settlement (empty = draft can settle now)
SELECT
  l.id AS listing_id,
  l.player_id,
  p."Name" AS player_name,
  l.listing_type,
  l.status,
  l.was_extended,
  COALESCE(l.initial_end_time, l.end_time) AT TIME ZONE 'Europe/London' AS scheduled_end_uk,
  l.end_time AT TIME ZONE 'Europe/London' AS current_end_uk,
  EXTRACT(
    HOUR FROM (
      COALESCE(l.initial_end_time, l.end_time) AT TIME ZONE 'Europe/London'
    )
  )::int AS scheduled_hour_uk
FROM public."Player_Transfer_Listings" l
LEFT JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
CROSS JOIN public.global_settings g
WHERE g.id = 1
  AND l.status = 'Active'
  AND l.listing_type IS DISTINCT FROM 'draft'
  AND l.end_time > now()
  AND public.gpsl_timestamptz_uk_date(
        COALESCE(l.initial_end_time, l.end_time)
      ) = public.gpsl_timestamptz_uk_date(g.draft_random_finish_time)
  AND (
    COALESCE(l.was_extended, false)
    OR EXTRACT(
          HOUR FROM (
            COALESCE(l.initial_end_time, l.end_time) AT TIME ZONE 'Europe/London'
          )
        )::int = 19
  )
ORDER BY l.end_time;

-- Run engine (blank result is NORMAL — transferengine_run returns void):
-- SELECT public.transferengine_run();
--
-- Prefer visible JSON report (deploy admin_transferengine_run.sql first):
-- SELECT public.transferengine_run_report();
--
-- pg_cron (primary automation — patches/transferengine_pg_cron.sql):
-- SELECT jobname, schedule, active FROM cron.job WHERE jobname LIKE 'gpsl-transfer-engine%';
-- SELECT status, start_time, end_time, return_message
-- FROM cron.job_run_details
-- WHERE jobid IN (SELECT jobid FROM cron.job WHERE jobname LIKE 'gpsl-transfer-engine%')
-- ORDER BY start_time DESC LIMIT 10;
--
-- Quick check after running:
-- SELECT status, transfer_completed, count(*) FROM public."Player_Transfer_Listings"
-- WHERE listing_type = 'draft' GROUP BY 1, 2 ORDER BY 1;
