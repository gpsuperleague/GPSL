-- =============================================================================
-- Allow proposing compromise midpoints even when mutual slots also exist
-- (2026-10-30)
--
-- UI shows blue "Compromise" chips: halfway between your slot and theirs when
-- the gap is under 2 hours, snapped to a UK 30-minute kick-off, and not already
-- an exact availability on either side. This lets fixture_schedule_propose
-- accept those times (same poke bypass path) without requiring zero mutuals.
--
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.match_schedule_snap_uk_half_hour(p_at timestamptz)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_local timestamp;
  v_floor timestamp;
BEGIN
  IF p_at IS NULL THEN
    RETURN NULL;
  END IF;
  v_local := p_at AT TIME ZONE 'Europe/London';
  v_floor := date_trunc('hour', v_local)
    + CASE
        WHEN EXTRACT(MINUTE FROM v_local) >= 30 THEN interval '30 minutes'
        ELSE interval '0'
      END;
  RETURN v_floor AT TIME ZONE 'Europe/London';
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_snap_uk_half_hour(timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_schedule_snap_uk_half_hour(timestamptz)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.match_schedule_kickoff_is_compromise_midpoint(
  p_fixture_id bigint,
  p_kickoff_at timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_home text;
  v_away text;
  v_target timestamptz := public.match_schedule_snap_uk_half_hour(p_kickoff_at);
BEGIN
  IF p_fixture_id IS NULL OR v_target IS NULL THEN
    RETURN false;
  END IF;

  SELECT f.home_club_short_name, f.away_club_short_name
  INTO v_home, v_away
  FROM public.competition_fixtures f
  WHERE f.id = p_fixture_id;

  IF v_home IS NULL OR v_away IS NULL THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.match_schedule_club_window_slots(p_fixture_id, v_home) h
    CROSS JOIN public.match_schedule_club_window_slots(p_fixture_id, v_away) a
    WHERE abs(extract(epoch FROM (h.kickoff_at - a.kickoff_at))) > 0
      AND abs(extract(epoch FROM (h.kickoff_at - a.kickoff_at))) < 7200
      AND public.match_schedule_snap_uk_half_hour(
            h.kickoff_at + ((a.kickoff_at - h.kickoff_at) / 2)
          ) = v_target
      -- Midpoint must not already be an exact slot for either club
      AND NOT EXISTS (
        SELECT 1
        FROM public.match_schedule_club_window_slots(p_fixture_id, v_home) x
        WHERE x.kickoff_at = v_target
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.match_schedule_club_window_slots(p_fixture_id, v_away) x
        WHERE x.kickoff_at = v_target
      )
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.match_schedule_kickoff_is_compromise_midpoint(bigint, timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_schedule_kickoff_is_compromise_midpoint(bigint, timestamptz)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.match_schedule_kickoff_is_compromise_midpoint(bigint, timestamptz) IS
  'True when kick-off is the UK 30-min midpoint of a home/away availability pair under 2h apart, and not already exact for either club.';

-- Expand poke-style availability bypass to also allow compromise midpoints
DO $propose$
DECLARE
  v_oid oid;
  v_def text;
BEGIN
  v_oid := to_regprocedure('public.fixture_schedule_propose(bigint,timestamptz)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'fixture_schedule_propose missing';
  END IF;

  v_def := replace(replace(pg_get_functiondef(v_oid), E'\r\n', E'\n'), E'\r', E'\n');

  IF position('match_schedule_kickoff_is_compromise_midpoint' IN v_def) > 0 THEN
    RAISE NOTICE 'fixture_schedule_propose already allows compromise midpoints';
    RETURN;
  END IF;

  -- Own-availability guard: also allow compromise midpoint
  IF position(
       E'IF NOT public.match_schedule_allow_free_propose(p_fixture_id)\n'
       || E'     AND NOT public.match_schedule_club_available_at'
       IN v_def
     ) > 0 THEN
    v_def := replace(
      v_def,
      E'IF NOT public.match_schedule_allow_free_propose(p_fixture_id)\n'
      || E'     AND NOT public.match_schedule_club_available_at',
      E'IF NOT public.match_schedule_allow_free_propose(p_fixture_id)\n'
      || E'     AND NOT public.match_schedule_kickoff_is_compromise_midpoint(p_fixture_id, p_kickoff_at)\n'
      || E'     AND NOT public.match_schedule_club_available_at'
    );
  END IF;

  -- Mutual / opponent guard: same
  IF position(
       E'IF NOT public.match_schedule_allow_free_propose(p_fixture_id)\n'
       || E'     AND (to_regprocedure(''public.competition_club_is_vacant'
       IN v_def
     ) > 0 THEN
    v_def := replace(
      v_def,
      E'IF NOT public.match_schedule_allow_free_propose(p_fixture_id)\n'
      || E'     AND (to_regprocedure(''public.competition_club_is_vacant',
      E'IF NOT public.match_schedule_allow_free_propose(p_fixture_id)\n'
      || E'     AND NOT public.match_schedule_kickoff_is_compromise_midpoint(p_fixture_id, p_kickoff_at)\n'
      || E'     AND (to_regprocedure(''public.competition_club_is_vacant'
    );
  END IF;

  IF position('match_schedule_kickoff_is_compromise_midpoint' IN v_def) = 0 THEN
    RAISE EXCEPTION
      'Could not inject compromise midpoint allow into fixture_schedule_propose';
  END IF;

  EXECUTE v_def;
  RAISE NOTICE 'fixture_schedule_propose: compromise midpoints allowed';
END;
$propose$;

NOTIFY pgrst, 'reload schema';

SELECT
  to_regprocedure('public.match_schedule_kickoff_is_compromise_midpoint(bigint,timestamptz)') IS NOT NULL
    AS compromise_fn,
  position('match_schedule_kickoff_is_compromise_midpoint' IN pg_get_functiondef(
    'public.fixture_schedule_propose(bigint,timestamptz)'::regprocedure
  )) > 0 AS propose_allows_compromise;
