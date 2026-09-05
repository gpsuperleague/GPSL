-- =============================================================================
-- Club suspensions start from the next GPSL month
--
-- Rule:
-- - Red card / yellow accumulation in month X
-- - Ban applies to the club's first 2 scheduled league/cup fixtures in month X+1
--   onward (not the rest of month X)
-- - Club and international suspensions do not cross over
-- - Injuries still cross over separately
--
-- Run after the suspension resync patches.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_next_club_fixtures(
  p_season_id bigint,
  p_club text,
  p_after_fixture_id bigint,
  p_limit int DEFAULT 2
)
RETURNS TABLE (fixture_id bigint, seq int)
LANGUAGE sql
STABLE
SET search_path = public
AS $function$
  WITH src AS (
    SELECT
      f.id,
      f.matchday,
      lower(coalesce(f.gpsl_month, '')) AS gpsl_month,
      coalesce(public.competition_gpsl_month_sort(lower(coalesce(f.gpsl_month, ''))), 0) AS month_sort,
      public.match_schedule_agreed_kickoff(f.id) AS kickoff_at
    FROM public.competition_fixtures f
    WHERE f.id = p_after_fixture_id
  ),
  upcoming AS (
    SELECT
      f.id,
      row_number() OVER (
        ORDER BY
          coalesce(public.competition_gpsl_month_sort(lower(coalesce(f.gpsl_month, ''))), 99),
          coalesce(f.matchday, 9999),
          CASE
            WHEN to_regprocedure('public.match_schedule_agreed_kickoff(bigint)') IS NOT NULL
            THEN coalesce(public.match_schedule_agreed_kickoff(f.id), 'infinity'::timestamptz)
            ELSE 'infinity'::timestamptz
          END,
          f.id
      )::int AS seq
    FROM public.competition_fixtures f
    LEFT JOIN src s ON true
    WHERE f.season_id = p_season_id
      AND f.status = 'scheduled'
      AND f.id IS DISTINCT FROM p_after_fixture_id
      AND (f.home_club_short_name = p_club OR f.away_club_short_name = p_club)
      AND (
        s.id IS NULL
        OR coalesce(public.competition_gpsl_month_sort(lower(coalesce(f.gpsl_month, ''))), 99) > coalesce(s.month_sort, 0)
      )
  )
  SELECT u.id, u.seq
  FROM upcoming u
  WHERE u.seq <= greatest(p_limit, 1);
$function$;

-- Repair existing active suspensions onto the next-month rule
SELECT public.competition_resync_pending_suspensions(NULL, NULL);

NOTIFY pgrst, 'reload schema';
