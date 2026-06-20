-- =============================================================================
-- Why didn't player draft auction winners get assigned?
-- Run in Supabase SQL Editor after THIS draft's secret finish.
-- Queries 5–6 only count signings AFTER global_settings.draft_random_finish_time
-- (ignores older test runs / previous auctions).
-- =============================================================================

-- 0) This draft window (anchor for all queries below)
SELECT
  g.draft_auction_start_time AT TIME ZONE 'Europe/London' AS this_draft_start_uk,
  g.draft_random_finish_time AT TIME ZONE 'Europe/London' AS this_draft_finish_uk,
  now() AT TIME ZONE 'Europe/London' AS server_now_uk,
  EXTRACT(EPOCH FROM (now() - g.draft_random_finish_time))::int AS seconds_since_finish
FROM public.global_settings g
WHERE g.id = 1;

-- 1) Engine prerequisites
SELECT
  g.draft_auction_enabled,
  g.manager_draft_auction_enabled,
  g.club_auction_enabled,
  g.draft_auction_start_time AT TIME ZONE 'Europe/London' AS draft_start_uk,
  g.draft_random_finish_time AT TIME ZONE 'Europe/London' AS secret_finish_uk,
  now() AT TIME ZONE 'Europe/London' AS server_now_uk,
  g.draft_random_finish_time IS NOT NULL
    AND now() >= g.draft_random_finish_time AS secret_finish_passed,
  (
    SELECT status FROM public.competition_seasons
    WHERE is_current = true ORDER BY id DESC LIMIT 1
  ) AS current_season_status,
  CASE
    WHEN g.draft_random_finish_time IS NULL THEN
      'BLOCKED: draft_random_finish_time is NULL (admin may have disabled draft or saved new schedule too early)'
    WHEN now() < g.draft_random_finish_time THEN
      'BLOCKED: still before secret finish — settlement has not started yet'
    WHEN NOT COALESCE(g.draft_auction_enabled, false) THEN
      'BLOCKED: draft_auction_enabled=false — player draft loop is skipped unless resilience patch applied'
    WHEN public.transferengine_standard_listings_block_draft_settlement(
      now(), g.draft_random_finish_time
    ) THEN
      'BLOCKED: waiting on same-evening 7pm transfer-list auction(s) — see query 3'
    ELSE
      'READY: engine should settle on next transferengine_run() tick'
  END AS player_draft_settlement_gate
FROM public.global_settings g
WHERE g.id = 1;

-- 2) Unsettled draft listings for THIS auction (created during current draft start)
SELECT
  l.status,
  l.transfer_completed,
  count(*) AS listings,
  count(*) FILTER (WHERE l.current_highest_bidder IS NOT NULL) AS with_leader,
  count(*) FILTER (WHERE p."Contracted_Team" IS NOT NULL AND btrim(p."Contracted_Team") <> '') AS player_already_signed
FROM public."Player_Transfer_Listings" l
LEFT JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
CROSS JOIN public.global_settings g
WHERE g.id = 1
  AND l.listing_type = 'draft'
  AND l.created_at >= g.draft_auction_start_time
GROUP BY 1, 2
ORDER BY 1, 2;

-- Sample rows: Active draft with a leader but player still FA
SELECT
  l.id AS listing_id,
  l.player_id,
  p."Name",
  l.status,
  l.transfer_completed,
  l.current_highest_bid,
  l.current_highest_bidder,
  p."Contracted_Team",
  (
    SELECT count(*)::int
    FROM public."Player_Transfer_Bids" b
    WHERE b.is_direct = true
      AND (b.listing_id = l.id OR btrim(b.player_id) = btrim(l.player_id))
  ) AS direct_bid_count,
  (
    SELECT b.bid_amount
    FROM public."Player_Transfer_Bids" b
    WHERE b.is_direct = true
      AND (b.listing_id = l.id OR btrim(b.player_id) = btrim(l.player_id))
    ORDER BY b.bid_amount DESC, b.bid_time ASC
    LIMIT 1
  ) AS top_bid_from_bids_table
FROM public."Player_Transfer_Listings" l
JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
CROSS JOIN public.global_settings g
WHERE g.id = 1
  AND l.listing_type = 'draft'
  AND l.created_at >= g.draft_auction_start_time
  AND l.status = 'Active'
  AND l.current_highest_bidder IS NOT NULL
ORDER BY l.current_highest_bid DESC NULLS LAST
LIMIT 40;

-- 3) Transfer-list rows blocking draft settlement (empty = not blocked)
SELECT
  l.id,
  l.player_id,
  p."Name",
  l.listing_type,
  l.status,
  l.was_extended,
  COALESCE(l.initial_end_time, l.end_time) AT TIME ZONE 'Europe/London' AS scheduled_end_uk,
  l.end_time AT TIME ZONE 'Europe/London' AS current_end_uk,
  l.end_time > now() AS still_running
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

-- 4) Run engine once and inspect JSON report (requires admin_transferengine_run.sql)
-- SELECT public.transferengine_run_report();

-- 5) Signings from THIS draft only (after secret finish — not older runs)
SELECT
  h.transfer_time AT TIME ZONE 'Europe/London' AS signed_uk,
  p."Name",
  h.buyer_club_id,
  h.fee,
  h.listing_id
FROM public."Transfer_History" h
LEFT JOIN public."Players" p ON p."Konami_ID"::text = h.player_id::text
CROSS JOIN public.global_settings g
WHERE g.id = 1
  AND h.seller_club_id IS NULL
  AND g.draft_random_finish_time IS NOT NULL
  AND h.transfer_time >= g.draft_random_finish_time
ORDER BY h.transfer_time DESC
LIMIT 100;

-- 6) This draft — settlement batches since finish (empty = none yet)
SELECT
  date_trunc('second', h.transfer_time AT TIME ZONE 'Europe/London') AS signed_uk_second,
  count(*) AS players_in_batch,
  count(*) FILTER (WHERE h.listing_id IS NOT NULL) AS with_listing_id
FROM public."Transfer_History" h
CROSS JOIN public.global_settings g
WHERE g.id = 1
  AND h.seller_club_id IS NULL
  AND g.draft_random_finish_time IS NOT NULL
  AND h.transfer_time >= g.draft_random_finish_time
GROUP BY 1
ORDER BY 1 DESC;

-- 7) Still stuck: Active draft listing has a leader but player still FREE AGENT
SELECT
  count(*) AS stuck_with_leader,
  count(*) FILTER (
    WHERE NOT EXISTS (
      SELECT 1 FROM public."Player_Transfer_Bids" b
      WHERE b.is_direct = true
        AND (b.listing_id = l.id OR btrim(b.player_id) = btrim(l.player_id))
    )
  ) AS leader_but_no_direct_bid_row,
  count(*) FILTER (
    WHERE EXISTS (
      SELECT 1 FROM public."Player_Transfer_Bids" b
      WHERE b.is_direct = true
        AND (b.listing_id = l.id OR btrim(b.player_id) = btrim(l.player_id))
    )
  ) AS has_direct_bid_row
FROM public."Player_Transfer_Listings" l
JOIN public."Players" p ON p."Konami_ID"::text = l.player_id::text
CROSS JOIN public.global_settings g
WHERE g.id = 1
  AND l.listing_type = 'draft'
  AND l.created_at >= g.draft_auction_start_time
  AND l.status = 'Active'
  AND l.current_highest_bidder IS NOT NULL
  AND (p."Contracted_Team" IS NULL OR btrim(p."Contracted_Team") = '');

-- 8) Closed draft listings this auction — did engine mark transfer_completed?
SELECT
  l.status,
  l.transfer_completed,
  count(*) AS listings
FROM public."Player_Transfer_Listings" l
CROSS JOIN public.global_settings g
WHERE g.id = 1
  AND l.listing_type = 'draft'
  AND l.created_at >= g.draft_auction_start_time
GROUP BY 1, 2
ORDER BY 1, 2;

-- 9) Backlog breakdown (deploy draft_settlement_accept_fix.sql for this RPC)
-- SELECT public.transferengine_diagnose_draft_backlog();

-- 10) Probe first N listings — surfaces errors hidden by settle loop (deploy draft_settlement_ledger_season_fix.sql)
-- SELECT public.transferengine_probe_draft_settlement(3);

-- 12) Single listing — surfaces assign/ledger errors (draft_settlement_assign_overload_fix.sql)
-- SELECT public.transferengine_try_accept_draft_sale(215);

-- 13) Stuck mid-backlog — sample errors (draft_settlement_stuck_diagnose.sql)
-- SELECT public.transferengine_diagnose_stuck_drafts(10);
-- SELECT public.transferengine_settle_player_draft_listings_report(100);
-- SELECT public.transferengine_diagnose_draft_backlog();
-- SELECT public.transferengine_explain_draft_listing(
--   (SELECT id FROM "Player_Transfer_Listings"
--    WHERE listing_type='draft' AND status='Active' ORDER BY id LIMIT 1)
-- );
