-- =============================================================================
-- Clear stuck schedule reply: ATM vs AND MD1 (2026-10-23)
-- =============================================================================
-- Atletico Madrid showing outstanding reply vs Anderlecht MD1 — blocks clean
-- re-arrange for testing. Resets that fixture's schedule to unscheduled,
-- clears response deadline, supersedes open proposals, drops check-ins.
-- Safe re-run. Does not touch scores / played fixtures.
-- =============================================================================

DO $clear$
DECLARE
  v_season_id bigint;
  v_fixture_id bigint;
  v_home text;
  v_away text;
  v_status text;
  v_sched text;
  v_reply text;
BEGIN
  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current season';
  END IF;

  SELECT f.id, f.home_club_short_name, f.away_club_short_name, f.status
  INTO v_fixture_id, v_home, v_away, v_status
  FROM public.competition_fixtures f
  WHERE f.season_id = v_season_id
    AND f.competition_type = 'league'
    AND f.matchday = 1
    AND (
      (upper(f.home_club_short_name) = 'ATM' AND upper(f.away_club_short_name) = 'AND')
      OR (upper(f.home_club_short_name) = 'AND' AND upper(f.away_club_short_name) = 'ATM')
    )
  ORDER BY f.id
  LIMIT 1;

  IF v_fixture_id IS NULL THEN
    RAISE EXCEPTION 'ATM vs AND league MD1 fixture not found on current season';
  END IF;

  IF v_status <> 'scheduled' THEN
    RAISE EXCEPTION 'Fixture % status is % — not clearing (expected scheduled)',
      v_fixture_id, v_status;
  END IF;

  SELECT s.status, s.response_required_club_short_name
  INTO v_sched, v_reply
  FROM public.competition_fixture_schedule s
  WHERE s.fixture_id = v_fixture_id;

  RAISE NOTICE 'Before: fixture_id=% % vs % sched=% reply_from=%',
    v_fixture_id, v_home, v_away, coalesce(v_sched, 'none'), coalesce(v_reply, 'none');

  -- Close open proposals
  UPDATE public.competition_fixture_schedule_proposal
  SET status = 'superseded'
  WHERE fixture_id = v_fixture_id
    AND status = 'pending';

  -- Cancel pending mutual overrides
  IF to_regclass('public.competition_fixture_mutual_override') IS NOT NULL THEN
    UPDATE public.competition_fixture_mutual_override
    SET status = 'cancelled'
    WHERE fixture_id = v_fixture_id
      AND status = 'pending';
  END IF;

  -- Full schedule reset (unscheduled + clear KO + check-ins)
  IF to_regprocedure('public.match_schedule_reset_to_unscheduled(bigint)') IS NOT NULL THEN
    PERFORM public.match_schedule_reset_to_unscheduled(v_fixture_id);
  ELSE
    UPDATE public.competition_fixture_schedule
    SET
      status = 'unscheduled',
      agreed_kickoff_at = NULL,
      pending_proposal_id = NULL,
      updated_at = now()
    WHERE fixture_id = v_fixture_id;

    DELETE FROM public.competition_fixture_checkin
    WHERE fixture_id = v_fixture_id;
  END IF;

  -- Clear reply clock / miss counters / proposal caps (fresh arrange for testing)
  UPDATE public.competition_fixture_schedule
  SET
    response_due_at = NULL,
    response_required_club_short_name = NULL,
    response_miss_count = 0,
    home_proposal_count = 0,
    away_proposal_count = 0,
    pending_proposal_id = NULL,
    agreed_kickoff_at = NULL,
    status = 'unscheduled',
    updated_at = now()
  WHERE fixture_id = v_fixture_id;

  BEGIN
    UPDATE public.competition_fixture_schedule
    SET response_deadline_warned_at = NULL
    WHERE fixture_id = v_fixture_id;
  EXCEPTION WHEN undefined_column THEN
    NULL;
  END;

  -- Archive schedule inbox items for both clubs on this fixture
  IF to_regclass('public.competition_inbox') IS NOT NULL THEN
    BEGIN
      UPDATE public.competition_inbox
      SET
        read_at = coalesce(read_at, now()),
        archived_at = coalesce(archived_at, now())
      WHERE fixture_id = v_fixture_id
        AND recipient_club_short_name IN (v_home, v_away)
        AND message_type IN (
          'match_time_proposed',
          'match_time_countered',
          'match_time_accepted',
          'match_rescheduled',
          'match_emergency_drop',
          'mutual_override_request',
          'response_deadline_warning'
        )
        AND archived_at IS NULL;
    EXCEPTION WHEN undefined_column OR check_violation THEN
      NULL;
    END;
  END IF;

  SELECT s.status, s.response_required_club_short_name
  INTO v_sched, v_reply
  FROM public.competition_fixture_schedule s
  WHERE s.fixture_id = v_fixture_id;

  RAISE NOTICE 'After: fixture_id=% sched=% reply_from=% — home can propose again.',
    v_fixture_id, coalesce(v_sched, 'none'), coalesce(v_reply, 'none');
END;
$clear$;

-- Report
SELECT
  f.id AS fixture_id,
  f.matchday,
  f.home_club_short_name AS home,
  f.away_club_short_name AS away,
  f.status AS fixture_status,
  s.status AS schedule_status,
  s.agreed_kickoff_at,
  s.pending_proposal_id,
  s.response_required_club_short_name AS reply_from,
  s.response_due_at,
  (
    SELECT count(*) FROM public.competition_fixture_schedule_proposal p
    WHERE p.fixture_id = f.id AND p.status = 'pending'
  ) AS pending_proposals
FROM public.competition_fixtures f
JOIN public.competition_seasons se ON se.id = f.season_id AND se.is_current
LEFT JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
WHERE f.competition_type = 'league'
  AND f.matchday = 1
  AND (
    (upper(f.home_club_short_name) = 'ATM' AND upper(f.away_club_short_name) = 'AND')
    OR (upper(f.home_club_short_name) = 'AND' AND upper(f.away_club_short_name) = 'ATM')
  );
