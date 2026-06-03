-- =============================================================================
-- Repair transfer-list end times → 7pm UK (Europe/London), incl. direct listings
-- Run in Supabase SQL Editor. Safe to re-run.
-- Requires: compute_standard_listing_end_time (from recalc_standard_listing_end_times.sql)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- A) READ: listing 170 + any direct row that is not 7pm UK on end_time
-- ---------------------------------------------------------------------------
SELECT
  l.id,
  l.player_id,
  l.listing_type,
  l.status,
  l.start_time,
  (l.start_time AT TIME ZONE 'Europe/London') AS start_uk,
  l.initial_end_time,
  (l.initial_end_time AT TIME ZONE 'Europe/London') AS initial_end_uk,
  l.end_time,
  (l.end_time AT TIME ZONE 'Europe/London') AS end_uk,
  EXTRACT(HOUR FROM l.end_time AT TIME ZONE 'Europe/London')::int AS end_hour_uk,
  public.compute_standard_listing_end_time(COALESCE(l.start_time, l.created_at)) AS computed_end,
  (public.compute_standard_listing_end_time(COALESCE(l.start_time, l.created_at))
     AT TIME ZONE 'Europe/London') AS computed_end_uk,
  l.end_time - l.initial_end_time AS drift,
  l.was_extended
FROM public."Player_Transfer_Listings" l
WHERE l.id = 170
   OR (
     l.status = 'Active'
     AND l.listing_type = 'direct'
     AND COALESCE(l.transfer_completed, false) = false
   )
ORDER BY l.id;

-- All active standard/direct not clearly ending 7:00pm UK (wall clock)
SELECT
  l.id,
  l.listing_type,
  (l.end_time AT TIME ZONE 'Europe/London') AS end_uk,
  (l.initial_end_time AT TIME ZONE 'Europe/London') AS initial_end_uk
FROM public."Player_Transfer_Listings" l
WHERE l.status = 'Active'
  AND l.listing_type IS DISTINCT FROM 'draft'
  AND COALESCE(l.transfer_completed, false) = false
  AND COALESCE(l.was_extended, false) = false
  AND COALESCE(l.hour_extended, false) = false
  AND (
    (l.end_time AT TIME ZONE 'Europe/London')::time IS DISTINCT FROM time '19:00:00'
    OR (l.initial_end_time AT TIME ZONE 'Europe/London')::time IS DISTINCT FROM time '19:00:00'
    OR l.end_time IS DISTINCT FROM l.initial_end_time
  )
ORDER BY l.id;

-- ---------------------------------------------------------------------------
-- B) FIX 1: classic 1h drift (end = initial when exactly +1 hour)
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- C) FIX 2: direct listings — both times = computed 7pm UK from start_time
--     (covers 170 even if drift fix already ran; skips engine-extended rows)
-- ---------------------------------------------------------------------------
UPDATE public."Player_Transfer_Listings" l
SET
  end_time = public.compute_standard_listing_end_time(COALESCE(l.start_time, l.created_at)),
  initial_end_time = public.compute_standard_listing_end_time(COALESCE(l.start_time, l.created_at))
WHERE l.status = 'Active'
  AND l.listing_type = 'direct'
  AND COALESCE(l.transfer_completed, false) = false
  AND COALESCE(l.was_extended, false) = false
  AND COALESCE(l.hour_extended, false) = false
  AND (
    l.end_time IS DISTINCT FROM public.compute_standard_listing_end_time(
      COALESCE(l.start_time, l.created_at)
    )
    OR l.initial_end_time IS DISTINCT FROM public.compute_standard_listing_end_time(
      COALESCE(l.start_time, l.created_at)
    )
  );

-- ---------------------------------------------------------------------------
-- D) VERIFY: listing 170 must show 19:00 UK on both ends (= 18:00 UTC in BST)
-- ---------------------------------------------------------------------------
SELECT
  l.id,
  l.listing_type,
  l.end_time AS end_utc,
  l.initial_end_time AS initial_utc,
  (l.end_time AT TIME ZONE 'Europe/London') AS end_uk,
  (l.initial_end_time AT TIME ZONE 'Europe/London') AS initial_end_uk,
  (l.end_time AT TIME ZONE 'Europe/London')::time = time '19:00:00' AS is_7pm_uk,
  l.end_time = l.initial_end_time AS end_matches_initial
FROM public."Player_Transfer_Listings" l
WHERE l.id = 170;

-- Should return no rows: no active non-extended listing with wrong UK end
SELECT l.id, l.listing_type, (l.end_time AT TIME ZONE 'Europe/London') AS end_uk
FROM public."Player_Transfer_Listings" l
WHERE l.status = 'Active'
  AND l.listing_type IS DISTINCT FROM 'draft'
  AND COALESCE(l.was_extended, false) = false
  AND (
    (l.end_time AT TIME ZONE 'Europe/London')::time IS DISTINCT FROM time '19:00:00'
    OR l.end_time IS DISTINCT FROM l.initial_end_time
  );
