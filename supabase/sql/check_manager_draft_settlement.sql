-- =============================================================================
-- Manager draft settlement diagnostic (read-only)
-- Run in Supabase SQL Editor after the random finish has passed.
-- =============================================================================

SELECT
  g.manager_draft_auction_enabled,
  g.draft_auction_enabled,
  g.draft_random_finish_time,
  g.draft_random_finish_time AT TIME ZONE 'Europe/London' AS random_finish_uk,
  now() AT TIME ZONE 'Europe/London' AS server_now_uk,
  g.draft_random_finish_time IS NOT NULL AND now() >= g.draft_random_finish_time AS secret_finish_passed,
  public.transferengine_standard_listings_block_draft_settlement(
    now(),
    g.draft_random_finish_time
  ) AS blocked_by_active_7pm_transfer_list,
  (
    SELECT count(*)::int
    FROM public."Manager_Transfer_Listings" l
    WHERE l.listing_type = 'draft' AND l.status = 'Active'
  ) AS active_manager_draft_listings,
  CASE
    WHEN g.draft_random_finish_time IS NULL THEN 'no random finish set — re-save draft in Admin'
    WHEN now() < g.draft_random_finish_time THEN 'before secret finish'
    WHEN (
      SELECT count(*)::int
      FROM public."Manager_Transfer_Listings" l
      WHERE l.listing_type = 'draft' AND l.status = 'Active'
    ) > 0
    AND NOT COALESCE(g.manager_draft_auction_enabled, false)
      THEN 'manager draft toggle off but Active listings remain — run patches/manager_draft_settlement_residue_hotfix.sql then admin_settle_manager_drafts_now()'
    WHEN NOT COALESCE(g.manager_draft_auction_enabled, false) THEN 'manager draft disabled (no active listings)'
    WHEN public.transferengine_standard_listings_block_draft_settlement(
      now(),
      g.draft_random_finish_time
    ) THEN 'player draft blocked by 7pm list — manager draft still settles (check engine cron or run admin_settle_manager_drafts_now)'
    WHEN to_regprocedure('public.manager_assign_to_club(bigint, text, smallint, numeric, boolean, jsonb)') IS NULL
      THEN 'run patches/manager_draft_auto_settle.sql (manager_assign_to_club missing)'
    WHEN to_regprocedure('public.admin_settle_manager_drafts_now()') IS NULL
      THEN 'run patches/manager_draft_settlement_fix.sql'
    ELSE 'ready — auto via transferengine_run cron after random finish, or Admin → Settle manager drafts now'
  END AS manager_settlement_status
FROM public.global_settings g
WHERE g.id = 1;

-- Active manager draft threads still waiting
SELECT
  l.id AS listing_id,
  l.manager_id,
  m.name AS manager_name,
  l.status,
  l.current_highest_bid,
  l.current_highest_bidder,
  l.transfer_completed,
  l.created_at,
  c.manager_id AS winner_club_manager_id,
  EXISTS (
    SELECT 1 FROM public."Managers" mx
    WHERE mx.contracted_club = l.current_highest_bidder
  ) AS winner_already_has_manager
FROM public."Manager_Transfer_Listings" l
LEFT JOIN public."Managers" m ON m.id = l.manager_id
LEFT JOIN public."Clubs" c ON c."ShortName" = l.current_highest_bidder
WHERE l.listing_type = 'draft'
  AND l.status = 'Active'
ORDER BY l.id;

-- Player transfer-list rows blocking draft settlement (empty = can settle)
SELECT
  l.id AS listing_id,
  l.player_id,
  l.status,
  l.was_extended,
  l.end_time AT TIME ZONE 'Europe/London' AS current_end_uk
FROM public."Player_Transfer_Listings" l
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

-- Run engine (blank result is normal — returns void):
-- SELECT public.transferengine_run();
--
-- Or visible JSON report:
-- SELECT public.admin_transferengine_run();
--
-- Probe one listing (shows real error text):
-- SELECT public.transferengine_probe_manager_draft_settlement(5);
