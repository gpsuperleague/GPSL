-- =============================================================================
-- Recalculate end_time for active standard/direct listings (24h + 7pm UK rule)
-- Run once in Supabase SQL Editor after deploying computeStandardListingEndTime in the app.
-- Safe to re-run: only extends end_time (never shortens); skips draft listings.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.compute_standard_listing_end_time(p_start timestamptz)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $function$
DECLARE
  v_min_end   timestamptz;
  v_uk_local  timestamp;
  v_uk_date   date;
  v_uk_time   time;
  v_next19    timestamptz;
  v_add_day   int;
BEGIN
  IF p_start IS NULL THEN
    RETURN NULL;
  END IF;

  v_min_end := p_start + interval '24 hours';
  v_uk_local := v_min_end AT TIME ZONE 'Europe/London';
  v_uk_date := v_uk_local::date;
  v_uk_time := v_uk_local::time;

  IF EXTRACT(HOUR FROM v_uk_time) > 19
     OR (
       EXTRACT(HOUR FROM v_uk_time) = 19
       AND (
         EXTRACT(MINUTE FROM v_uk_time) > 0
         OR EXTRACT(SECOND FROM v_uk_time) > 0
       )
     )
  THEN
    v_add_day := 1;
  ELSE
    v_add_day := 0;
  END IF;

  v_next19 :=
    ((v_uk_date + v_add_day)::timestamp + time '19:00:00')
    AT TIME ZONE 'Europe/London';

  IF v_min_end > v_next19 THEN
    RETURN v_min_end;
  END IF;
  RETURN v_next19;
END;
$function$;

-- Preview (optional): see old vs new before updating
-- SELECT id, player_id, seller_club_id, start_time, end_time AS old_end,
--   public.compute_standard_listing_end_time(COALESCE(start_time, created_at)) AS new_end
-- FROM "Player_Transfer_Listings"
-- WHERE status = 'Active'
--   AND listing_type IS DISTINCT FROM 'draft';

UPDATE public."Player_Transfer_Listings" l
SET
  end_time = CASE
    WHEN COALESCE(l.was_extended, false)
      OR COALESCE(l.hour_extended, false)
    THEN GREATEST(
      l.end_time,
      public.compute_standard_listing_end_time(COALESCE(l.start_time, l.created_at))
    )
    ELSE public.compute_standard_listing_end_time(COALESCE(l.start_time, l.created_at))
  END,
  initial_end_time = CASE
    WHEN COALESCE(l.was_extended, false)
      OR COALESCE(l.hour_extended, false)
    THEN l.initial_end_time
    ELSE public.compute_standard_listing_end_time(COALESCE(l.start_time, l.created_at))
  END
WHERE l.status = 'Active'
  AND l.listing_type IS DISTINCT FROM 'draft'
  AND COALESCE(l.transfer_completed, false) = false;
