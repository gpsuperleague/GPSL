-- =============================================================================
-- Clear ALL stuck match-proposal replies for ATM (Ready for August) — 2026-10-23
-- =============================================================================
-- Checklist item "Replied to every match proposal" counts fixtures where:
--   schedule.status = 'negotiating'
--   AND response_required_club_short_name = ATM
-- Inbox can be empty if proposals were superseded / archived but the reply
-- clock was left set — matches locked with "1 waiting for your reply".
-- This clears every such ATM row on the current season so they can check in.
-- Safe re-run.
-- =============================================================================

-- 1) Before: what the checklist still sees
SELECT
  f.id AS fixture_id,
  f.matchday,
  f.gpsl_month,
  f.competition_type,
  f.home_club_short_name AS home,
  f.away_club_short_name AS away,
  s.status AS schedule_status,
  s.response_required_club_short_name AS reply_from,
  s.response_due_at,
  s.pending_proposal_id,
  (
    SELECT count(*) FROM public.competition_fixture_schedule_proposal p
    WHERE p.fixture_id = f.id AND p.status = 'pending'
  ) AS pending_proposals
FROM public.competition_fixtures f
JOIN public.competition_seasons se ON se.id = f.season_id AND se.is_current
JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
WHERE f.status = 'scheduled'
  AND s.status = 'negotiating'
  AND upper(btrim(coalesce(s.response_required_club_short_name, ''))) = 'ATM'
ORDER BY f.matchday, f.id;

DO $clear$
DECLARE
  v_season_id bigint;
  v_ids bigint[];
  v_n int := 0;
  fid bigint;
BEGIN
  SELECT id INTO v_season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1;

  IF v_season_id IS NULL THEN
    RAISE EXCEPTION 'No current season';
  END IF;

  SELECT coalesce(array_agg(f.id), ARRAY[]::bigint[])
  INTO v_ids
  FROM public.competition_fixtures f
  JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
  WHERE f.season_id = v_season_id
    AND f.status = 'scheduled'
    AND s.status = 'negotiating'
    AND upper(btrim(coalesce(s.response_required_club_short_name, ''))) = 'ATM';

  FOREACH fid IN ARRAY v_ids LOOP
    -- Close dangling proposals
    UPDATE public.competition_fixture_schedule_proposal
    SET status = 'superseded'
    WHERE fixture_id = fid
      AND status = 'pending';

    IF to_regclass('public.competition_fixture_mutual_override') IS NOT NULL THEN
      UPDATE public.competition_fixture_mutual_override
      SET status = 'cancelled'
      WHERE fixture_id = fid
        AND status = 'pending';
    END IF;

    IF to_regprocedure('public.match_schedule_reset_to_unscheduled(bigint)') IS NOT NULL THEN
      PERFORM public.match_schedule_reset_to_unscheduled(fid);
    END IF;

    UPDATE public.competition_fixture_schedule
    SET
      status = 'unscheduled',
      agreed_kickoff_at = NULL,
      pending_proposal_id = NULL,
      response_due_at = NULL,
      response_required_club_short_name = NULL,
      response_miss_count = 0,
      home_proposal_count = 0,
      away_proposal_count = 0,
      updated_at = now()
    WHERE fixture_id = fid;

    BEGIN
      UPDATE public.competition_fixture_schedule
      SET response_deadline_warned_at = NULL
      WHERE fixture_id = fid;
    EXCEPTION WHEN undefined_column THEN
      NULL;
    END;

    DELETE FROM public.competition_fixture_checkin
    WHERE fixture_id = fid;

    -- Archive related inbox noise for ATM (+ opponent)
    IF to_regclass('public.competition_inbox') IS NOT NULL THEN
      BEGIN
        UPDATE public.competition_inbox i
        SET
          read_at = coalesce(i.read_at, now()),
          archived_at = coalesce(i.archived_at, now())
        WHERE i.fixture_id = fid
          AND i.archived_at IS NULL
          AND i.message_type IN (
            'match_time_proposed',
            'match_time_countered',
            'match_time_accepted',
            'match_rescheduled',
            'match_emergency_drop',
            'mutual_override_request',
            'response_deadline_warning'
          );
      EXCEPTION WHEN undefined_column OR check_violation THEN
        NULL;
      END;
    END IF;

    v_n := v_n + 1;
  END LOOP;

  RAISE NOTICE 'Cleared % ATM pending-reply fixture(s). Ready-for-August replies item should be done.', v_n;
END;
$clear$;

-- 2) After: should be empty
SELECT
  f.id AS fixture_id,
  f.matchday,
  f.home_club_short_name AS home,
  f.away_club_short_name AS away,
  s.status AS schedule_status,
  s.response_required_club_short_name AS reply_from
FROM public.competition_fixtures f
JOIN public.competition_seasons se ON se.id = f.season_id AND se.is_current
JOIN public.competition_fixture_schedule s ON s.fixture_id = f.id
WHERE f.status = 'scheduled'
  AND s.status = 'negotiating'
  AND upper(btrim(coalesce(s.response_required_club_short_name, ''))) = 'ATM';

-- 3) Checklist pulse for ATM
SELECT
  i->>'key' AS item,
  i->>'done' AS done,
  i->>'detail' AS detail
FROM jsonb_array_elements(
  public.gpsl_owner_ready_items('ATM', (
    SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
  ))
) i
WHERE i->>'key' IN ('replies', 'aug_proposed');
