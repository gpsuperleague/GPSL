-- =============================================================================
-- Admin one-shot: SuperLeague MD3 SLB vs CHE (fixture 8981) — allow replay
-- Reason: Chelsea illegal formation; August grace — reset schedule + videos.
-- Safe to re-run (idempotent cleans).
-- =============================================================================

DO $$
DECLARE
  v_fid bigint := 8981;
  v_f public.competition_fixtures%ROWTYPE;
  v_video jsonb;
  v_pending int;
  v_proposals int;
  v_inbox int;
BEGIN
  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = v_fid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture % not found', v_fid;
  END IF;

  IF v_f.competition_type IS DISTINCT FROM 'league'
     OR v_f.division IS DISTINCT FROM 'superleague'
     OR v_f.matchday IS DISTINCT FROM 3
     OR upper(v_f.home_club_short_name) IS DISTINCT FROM 'SLB'
     OR upper(v_f.away_club_short_name) IS DISTINCT FROM 'CHE' THEN
    RAISE EXCEPTION
      'Fixture % is not SL MD3 SLB vs CHE (got % % MD% % vs %)',
      v_fid,
      v_f.competition_type,
      v_f.division,
      v_f.matchday,
      v_f.home_club_short_name,
      v_f.away_club_short_name;
  END IF;

  IF v_f.status = 'played' THEN
    RAISE EXCEPTION 'Fixture % is already played — refusing schedule-only reset', v_fid;
  END IF;

  -- Videos (matched + pending ⏳) + reverse any gate credit when possible
  IF to_regprocedure('public.match_video_admin_clear(bigint, text)') IS NOT NULL THEN
    v_video := public.match_video_admin_clear(v_fid, NULL);
  END IF;
  IF v_video IS NULL OR coalesce((v_video->>'ok')::boolean, false) IS NOT TRUE THEN
    DELETE FROM public.fixture_match_video_pending WHERE fixture_id = v_fid;
    GET DIAGNOSTICS v_pending = ROW_COUNT;
    DELETE FROM public.fixture_match_videos WHERE fixture_id = v_fid;
    v_video := coalesce(v_video, '{}'::jsonb) || jsonb_build_object(
      'fallback_pending_deleted', v_pending
    );
  END IF;

  -- Always ensure pending holds are gone (⏳ ticks)
  DELETE FROM public.fixture_match_video_pending WHERE fixture_id = v_fid;

  -- Breach reports against this fixture (if any) — archive note only
  UPDATE public.match_video_breach_reports
  SET review_note = trim(both E'\n' from coalesce(review_note, '') || E'\n' ||
        'Admin replay reset (illegal formation; August leeway) ' ||
        to_char(now() AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'))
  WHERE fixture_id = v_fid;

  -- Schedule proposals history
  DELETE FROM public.competition_fixture_schedule_proposal
  WHERE fixture_id = v_fid;
  GET DIAGNOSTICS v_proposals = ROW_COUNT;

  -- Check-ins
  DELETE FROM public.competition_fixture_checkin
  WHERE fixture_id = v_fid;

  -- Full schedule wipe → unscheduled (proposal counters zeroed)
  UPDATE public.competition_fixture_schedule
  SET
    status = 'unscheduled',
    agreed_kickoff_at = NULL,
    pending_proposal_id = NULL,
    response_due_at = NULL,
    response_required_club_short_name = NULL,
    response_miss_count = 0,
    no_show_club_short_name = NULL,
    no_show_kickoff_at = NULL,
    home_proposal_count = 0,
    away_proposal_count = 0,
    discord_hint_shown = false,
    mutual_override_used = false,
    updated_at = now()
  WHERE fixture_id = v_fid;

  IF NOT FOUND THEN
    INSERT INTO public.competition_fixture_schedule (fixture_id, status)
    VALUES (v_fid, 'unscheduled')
    ON CONFLICT (fixture_id) DO UPDATE
    SET status = 'unscheduled',
        agreed_kickoff_at = NULL,
        pending_proposal_id = NULL,
        home_proposal_count = 0,
        away_proposal_count = 0,
        updated_at = now();
  END IF;

  -- Archive schedule-related inbox items for both clubs
  UPDATE public.competition_inbox
  SET archived_at = coalesce(archived_at, now()),
      read_at = coalesce(read_at, now())
  WHERE fixture_id = v_fid
    AND archived_at IS NULL
    AND message_type IN (
      'match_time_proposed',
      'match_time_countered',
      'match_time_proposal_sent',
      'match_time_counter_sent',
      'match_time_accepted',
      'match_rescheduled',
      'match_emergency_drop',
      'match_checkin_open',
      'match_mutual_override_requested',
      'match_mutual_override_applied',
      'result_to_confirm',
      'result_submitted'
    );
  GET DIAGNOSTICS v_inbox = ROW_COUNT;

  RAISE NOTICE 'Reset fixture % SLB vs CHE MD3 — proposals=% videos=% inbox=%',
    v_fid, v_proposals, v_video, coalesce(v_inbox, 0);
END;
$$;

-- Verify
SELECT
  f.id,
  f.status AS fixture_status,
  f.home_club_short_name,
  f.away_club_short_name,
  f.matchday,
  sch.status AS schedule_status,
  sch.agreed_kickoff_at,
  sch.home_proposal_count,
  sch.away_proposal_count,
  (SELECT count(*) FROM public.competition_fixture_schedule_proposal p WHERE p.fixture_id = f.id) AS proposals_left,
  (SELECT count(*) FROM public.fixture_match_videos v WHERE v.fixture_id = f.id) AS videos_left,
  (SELECT count(*) FROM public.fixture_match_video_pending pv WHERE pv.fixture_id = f.id) AS pending_videos_left,
  (SELECT count(*) FROM public.competition_fixture_checkin c WHERE c.fixture_id = f.id) AS checkins_left
FROM public.competition_fixtures f
LEFT JOIN public.competition_fixture_schedule sch ON sch.fixture_id = f.id
WHERE f.id = 8981;
