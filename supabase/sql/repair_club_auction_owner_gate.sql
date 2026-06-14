-- =============================================================================
-- Diagnose club auction winner still on awaiting_club (run in SQL Editor)
-- =============================================================================

-- 1) Secret finish time — settlement only auto-runs after this (cron / transfer engine)
SELECT
  club_auction_enabled,
  draft_auction_start_time,
  draft_random_finish_time,
  now() AS server_now,
  (draft_random_finish_time IS NOT NULL AND now() >= draft_random_finish_time) AS secret_finish_passed
FROM public.global_settings
WHERE id = 1;

-- 2) owner1@gmail.com — registry + club attachment
SELECT
  u.email,
  u.id AS owner_id,
  r.status AS registry_status,
  r.pending_starting_balance,
  c."ShortName" AS club_short,
  c."Club" AS club_name
FROM auth.users u
LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = u.id
LEFT JOIN public."Clubs" c ON c.owner_id = u.id
WHERE lower(u.email) LIKE 'owner1%'
ORDER BY u.email;

-- 3) Active listings still waiting settlement (admin must settle if finish passed)
SELECT
  l.id,
  l.club_short_name,
  l.status,
  l.transfer_completed,
  l.current_highest_bid,
  l.current_highest_bidder,
  r.owner_tag AS leader_tag,
  l.winning_bid,
  l.winning_owner_id
FROM public."Club_Auction_Listings" l
LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = l.current_highest_bidder
WHERE l.status = 'Active'
ORDER BY l.prestige_rank NULLS LAST, l.club_short_name;

-- 4) Recently closed club auction listings
SELECT
  l.id,
  l.club_short_name,
  l.status,
  l.transfer_completed,
  l.winning_bid,
  l.winning_owner_id,
  r.owner_tag,
  c.owner_id AS club_owner_id_now
FROM public."Club_Auction_Listings" l
LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = l.winning_owner_id
LEFT JOIN public."Clubs" c ON c."ShortName" = l.club_short_name
WHERE l.status = 'Closed'
ORDER BY l.updated_at DESC
LIMIT 20;

-- 5) FIX — settle all active club auction listings now (admin UI does the same RPC)
-- SELECT public.admin_settle_club_auctions_now();

NOTIFY pgrst, 'reload schema';
