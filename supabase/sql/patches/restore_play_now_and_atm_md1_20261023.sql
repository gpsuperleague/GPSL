-- =============================================================================
-- Restore Play now on AND vs ATM league MD1 only (2026-10-23)
-- =============================================================================
-- Does NOT reset kick-off / proposals / check-ins.
-- Only clears mutual_override_used (+ cancels a stuck pending override request)
-- so the Play now button can show again on an already-agreed schedule.
-- Safe re-run. Touches this one fixture only.
-- =============================================================================

DO $fix$
DECLARE
  v_fixture_id bigint;
  v_home text;
  v_away text;
  v_status text;
  v_ko timestamptz;
  v_used boolean;
BEGIN
  SELECT f.id, f.home_club_short_name, f.away_club_short_name,
         s.status, s.agreed_kickoff_at, coalesce(s.mutual_override_used, false)
  INTO v_fixture_id, v_home, v_away, v_status, v_ko, v_used
  FROM public.competition_fixtures f
  JOIN public.competition_seasons se ON se.id = f.season_id AND se.is_current
  LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
  WHERE f.competition_type = 'league'
    AND f.matchday = 1
    AND f.status = 'scheduled'
    AND (
      (upper(f.home_club_short_name) = 'AND' AND upper(f.away_club_short_name) = 'ATM')
      OR (upper(f.home_club_short_name) = 'ATM' AND upper(f.away_club_short_name) = 'AND')
    )
  ORDER BY f.id
  LIMIT 1;

  IF v_fixture_id IS NULL THEN
    RAISE EXCEPTION 'AND vs ATM league MD1 not found';
  END IF;

  RAISE NOTICE 'Fixture % (% vs %) schedule=% ko=% mutual_override_used=%',
    v_fixture_id, v_home, v_away, coalesce(v_status, 'none'), v_ko, v_used;

  -- Drop a half-finished mutual request that can hide the buttons
  IF to_regclass('public.competition_fixture_mutual_override') IS NOT NULL THEN
    UPDATE public.competition_fixture_mutual_override
    SET status = 'cancelled'
    WHERE fixture_id = v_fixture_id
      AND status = 'pending';
  END IF;

  -- Re-enable one mutual override (Play now / new time) — do not touch agreed KO
  UPDATE public.competition_fixture_schedule
  SET
    mutual_override_used = false,
    updated_at = now()
  WHERE fixture_id = v_fixture_id;

  RAISE NOTICE 'Play now re-enabled on fixture % (kick-off left as-is).', v_fixture_id;
END;
$fix$;

SELECT
  f.id AS fixture_id,
  f.home_club_short_name AS home,
  f.away_club_short_name AS away,
  s.status AS schedule_status,
  s.agreed_kickoff_at,
  s.mutual_override_used,
  (
    SELECT count(*) FROM public.competition_fixture_mutual_override mo
    WHERE mo.fixture_id = f.id AND mo.status = 'pending'
  ) AS pending_mutual_requests
FROM public.competition_fixtures f
JOIN public.competition_seasons se ON se.id = f.season_id AND se.is_current
LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
WHERE f.competition_type = 'league'
  AND f.matchday = 1
  AND (
    (upper(f.home_club_short_name) = 'AND' AND upper(f.away_club_short_name) = 'ATM')
    OR (upper(f.home_club_short_name) = 'ATM' AND upper(f.away_club_short_name) = 'AND')
  );
