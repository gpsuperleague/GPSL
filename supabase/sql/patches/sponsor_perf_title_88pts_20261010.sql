-- =============================================================================
-- Performance sponsor: title favourites must win the league with 88+ points
-- (2026-10-10)
-- =============================================================================
-- The performance deal pays its bonus when a club finishes ABOVE its expected
-- league position. A club expected to finish 1st could never do that. Now:
--   • expected 2nd or lower → finish above expected position (unchanged)
--   • expected 1st          → win the league with at least
--                             club_commercial_settings.perf_title_min_points
--                             league points (default 88, incl. adjustments)
-- Patches the bonus line in competition_post_commercial_eos in place.
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.club_commercial_settings
  ADD COLUMN IF NOT EXISTS perf_title_min_points int NOT NULL DEFAULT 88;

-- League points for a season (played league fixtures + points adjustments).
CREATE OR REPLACE FUNCTION public.competition_club_league_match_points(
  p_season_id bigint,
  p_club_short_name text
)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT (
    coalesce((
      SELECT sum(
        CASE
          WHEN f.is_void THEN 0
          WHEN f.home_club_short_name = p_club_short_name THEN
            CASE WHEN f.home_goals > f.away_goals THEN 3 WHEN f.home_goals = f.away_goals THEN 1 ELSE 0 END
          ELSE
            CASE WHEN f.away_goals > f.home_goals THEN 3 WHEN f.away_goals = f.home_goals THEN 1 ELSE 0 END
        END)
      FROM public.competition_fixtures f
      WHERE f.season_id = p_season_id
        AND f.competition_type = 'league'
        AND f.status = 'played'
        AND p_club_short_name IN (f.home_club_short_name, f.away_club_short_name)
        AND (f.is_void OR (f.home_goals IS NOT NULL AND f.away_goals IS NOT NULL))
        AND public.competition_fixture_counts_in_tables(f.id)
    ), 0)
    + coalesce((
      SELECT sum(a.points_delta)
      FROM public.competition_league_points_adjustments a
      WHERE a.season_id = p_season_id AND a.club_short_name = p_club_short_name
    ), 0)
  )::int;
$$;

GRANT EXECUTE ON FUNCTION public.competition_club_league_match_points(bigint, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.club_commercial_perf_target_met(
  p_club_short_name text,
  p_season_id bigint,
  p_expected_pos int,
  p_actual_pos int
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_min int;
BEGIN
  IF p_expected_pos IS NULL OR p_actual_pos IS NULL THEN
    RETURN false;
  END IF;
  IF p_expected_pos > 1 THEN
    RETURN p_actual_pos < p_expected_pos;
  END IF;
  IF p_actual_pos <> 1 THEN
    RETURN false;
  END IF;
  SELECT coalesce(s.perf_title_min_points, 88) INTO v_min
  FROM public.club_commercial_settings s WHERE s.id = 1;
  RETURN public.competition_club_league_match_points(p_season_id, p_club_short_name) >= coalesce(v_min, 88);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.club_commercial_perf_target_met(text, bigint, int, int) TO authenticated;

DO $inject$
DECLARE
  v_def text;
  v_old text := 'v_pass := v_exp IS NOT NULL AND v_act IS NOT NULL AND v_act < v_exp;';
  v_new text := 'v_pass := public.club_commercial_perf_target_met(r.club, p_season_id, v_exp, v_act);';
  v_old_desc text := '(finished above expected position)';
  v_new_desc text := '(beat expectation)';
BEGIN
  SELECT pg_get_functiondef('public.competition_post_commercial_eos(bigint)'::regprocedure) INTO v_def;
  IF position(v_new IN v_def) > 0 THEN
    RAISE NOTICE 'competition_post_commercial_eos already uses the title rule';
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'competition_post_commercial_eos: performance line not found — not patched';
  END IF;
  v_def := replace(v_def, v_old, v_new);
  v_def := replace(v_def, v_old_desc, v_new_desc);
  EXECUTE v_def;
END;
$inject$;

NOTIFY pgrst, 'reload schema';

SELECT
  s.perf_title_min_points,
  position('club_commercial_perf_target_met' IN
    pg_get_functiondef('public.competition_post_commercial_eos(bigint)'::regprocedure)) > 0 AS eos_patched
FROM public.club_commercial_settings s
WHERE s.id = 1;
