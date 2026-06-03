-- =============================================================================
-- Repair transfer-list listings where end_time is 1h ahead of initial_end_time
-- (BST summer: 7pm UK = 18:00 UTC, but end_time was stored as 19:00 UTC = 8pm UK)
-- Safe for real extensions: only touches rows with was_extended / hour_extended false.
-- Run once in Supabase SQL Editor. Re-run preview SELECT first if unsure.
-- =============================================================================

-- Preview rows that will be fixed
SELECT
  l.id,
  l.player_id,
  l.listing_type,
  l.seller_club_id,
  l.start_time,
  l.initial_end_time,
  l.end_time AS end_time_before,
  l.initial_end_time AS end_time_after,
  l.end_time - l.initial_end_time AS drift
FROM public."Player_Transfer_Listings" l
WHERE l.status = 'Active'
  AND l.listing_type IS DISTINCT FROM 'draft'
  AND COALESCE(l.transfer_completed, false) = false
  AND COALESCE(l.was_extended, false) = false
  AND COALESCE(l.hour_extended, false) = false
  AND l.initial_end_time IS NOT NULL
  AND l.end_time > l.initial_end_time
  AND l.end_time - l.initial_end_time = interval '1 hour'
ORDER BY l.id;

-- Align live end to scheduled 7pm slot (initial_end_time)
UPDATE public."Player_Transfer_Listings" l
SET end_time = l.initial_end_time
WHERE l.status = 'Active'
  AND l.listing_type IS DISTINCT FROM 'draft'
  AND COALESCE(l.transfer_completed, false) = false
  AND COALESCE(l.was_extended, false) = false
  AND COALESCE(l.hour_extended, false) = false
  AND l.initial_end_time IS NOT NULL
  AND l.end_time > l.initial_end_time
  AND l.end_time - l.initial_end_time = interval '1 hour';

-- Verify (should return 0 rows)
SELECT l.id, l.player_id, l.end_time, l.initial_end_time
FROM public."Player_Transfer_Listings" l
WHERE l.status = 'Active'
  AND l.listing_type IS DISTINCT FROM 'draft'
  AND COALESCE(l.was_extended, false) = false
  AND l.end_time - l.initial_end_time = interval '1 hour';
