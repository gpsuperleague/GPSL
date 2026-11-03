-- =============================================================================
-- Boardroom / stadium performance: unlock after month-1 calendar rolls
-- =============================================================================
-- Bug: competition_stadium_performance_status_ready required EVERY first-month
-- league fixture to be played. Catch-up / replay August ties still scheduled in
-- September left Club performance rating as "Pending — wait for the first
-- month’s fixtures" even though the live month had moved on.
--
-- Fix:
--   • Ignore void fixtures in the completeness check
--   • Also ready once the active GPSL month is strictly after the first league
--     month (calendar has rolled) — provisional table is fine for the board.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.competition_stadium_performance_status_ready(
  p_season_id bigint
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_status text;
  v_first_month text;
  v_active text;
  v_first_sort int;
  v_active_sort int;
  v_total int;
  v_played int;
BEGIN
  IF p_season_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT s.status INTO v_status
  FROM public.competition_seasons s
  WHERE s.id = p_season_id;

  IF v_status IS DISTINCT FROM 'active' THEN
    RETURN false;
  END IF;

  SELECT f.gpsl_month INTO v_first_month
  FROM public.competition_fixtures f
  WHERE f.season_id = p_season_id
    AND f.competition_type = 'league'
    AND f.gpsl_month IS NOT NULL
    AND btrim(f.gpsl_month) <> ''
  ORDER BY public.competition_gpsl_month_sort(f.gpsl_month) NULLS LAST, f.id
  LIMIT 1;

  IF v_first_month IS NULL THEN
    RETURN false;
  END IF;

  -- Calendar has moved past month 1 → unlock (live table is enough for the board)
  BEGIN
    v_active := public.competition_active_gpsl_month(p_season_id, now());
  EXCEPTION WHEN undefined_function THEN
    v_active := NULL;
  END;

  IF v_active IS NOT NULL AND btrim(v_active) <> '' THEN
    v_first_sort := public.competition_gpsl_month_sort(v_first_month);
    v_active_sort := public.competition_gpsl_month_sort(v_active);
    IF v_first_sort IS NOT NULL
       AND v_active_sort IS NOT NULL
       AND v_active_sort > v_first_sort THEN
      RETURN true;
    END IF;
  END IF;

  -- Still in month 1: unlock only when non-void league fixtures are all played
  SELECT
    count(*) FILTER (WHERE coalesce(f.is_void, false) = false)::int,
    count(*) FILTER (
      WHERE coalesce(f.is_void, false) = false
        AND f.status = 'played'
    )::int
  INTO v_total, v_played
  FROM public.competition_fixtures f
  WHERE f.season_id = p_season_id
    AND f.competition_type = 'league'
    AND f.gpsl_month = v_first_month;

  RETURN v_total > 0 AND v_played >= v_total;
END;
$function$;

REVOKE ALL ON FUNCTION public.competition_stadium_performance_status_ready(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.competition_stadium_performance_status_ready(bigint)
  TO authenticated, anon, service_role;

-- Sanity: should be true while active month is past August with leftover August ties
SELECT
  public.competition_stadium_performance_status_ready(
    (SELECT id FROM competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
  ) AS status_ready_now;
