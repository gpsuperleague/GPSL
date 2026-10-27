-- =============================================================================
-- Admin one-shot: SuperLeague MD1 SOA vs COR (fixture 8966) — full wipe + replay
-- Reason: Corinthians did not record — staff exemption to replay in September.
-- No new fines from this reset. Reverse any fixture-linked gate / TV / fines.
--
-- Does:
--   • clear videos (+ reverse video credits)
--   • undo result / submissions / player stats
--   • undo suspensions / injury links sourced from this fixture
--   • reverse finance ledger rows for this fixture
--   • wipe schedule → unscheduled (re-arrange in September catch-up window)
--   • rebuild match-fitness streaks for SOA + COR
--
-- Safe-ish re-run (idempotent cleans). Run in SQL Editor as admin/postgres.
-- =============================================================================

DO $$
DECLARE
  v_fid bigint := 8966;
  v_f public.competition_fixtures%ROWTYPE;
  v_home text;
  v_away text;
  v_video jsonb;
  v_ledger record;
  v_n int;
  v_stats int := 0;
  v_subs int := 0;
  v_ledger_n int := 0;
  v_susp int := 0;
  v_inj int := 0;
  v_fit jsonb;
BEGIN
  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = v_fid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture % not found', v_fid;
  END IF;

  IF v_f.competition_type IS DISTINCT FROM 'league'
     OR v_f.division IS DISTINCT FROM 'superleague'
     OR v_f.matchday IS DISTINCT FROM 1
     OR upper(v_f.home_club_short_name) IS DISTINCT FROM 'SOA'
     OR upper(v_f.away_club_short_name) IS DISTINCT FROM 'COR' THEN
    RAISE EXCEPTION
      'Fixture % is not SL MD1 SOA vs COR (got % % MD% % vs %)',
      v_fid,
      v_f.competition_type,
      v_f.division,
      v_f.matchday,
      v_f.home_club_short_name,
      v_f.away_club_short_name;
  END IF;

  v_home := upper(btrim(v_f.home_club_short_name));
  v_away := upper(btrim(v_f.away_club_short_name));

  -- 1) Videos
  IF to_regprocedure('public.match_video_admin_clear(bigint, text)') IS NOT NULL THEN
    v_video := public.match_video_admin_clear(v_fid, NULL);
  END IF;
  DELETE FROM public.fixture_match_video_pending WHERE fixture_id = v_fid;
  DELETE FROM public.fixture_match_videos WHERE fixture_id = v_fid;

  UPDATE public.match_video_breach_reports
  SET review_note = trim(both E'\n' from coalesce(review_note, '') || E'\n' ||
        'Admin full wipe + September replay exemption (COR no recording) ' ||
        to_char(now() AT TIME ZONE 'Europe/London', 'YYYY-MM-DD HH24:MI'))
  WHERE fixture_id = v_fid;

  -- 2) Finance reverse (gate / TV / fines / anything linked to this fixture)
  --    Video credits already reversed by match_video_admin_clear when present.
  FOR v_ledger IN
    SELECT id, club_short_name, entry_type, amount
    FROM public.competition_finance_ledger
    WHERE fixture_id = v_fid
      AND entry_type IS DISTINCT FROM 'gate_match_video' -- already handled above
  LOOP
    IF to_regprocedure('public.competition_credit_club_balance(text, numeric)') IS NOT NULL THEN
      PERFORM public.competition_credit_club_balance(
        v_ledger.club_short_name,
        -coalesce(v_ledger.amount, 0)
      );
    END IF;
    DELETE FROM public.competition_finance_ledger WHERE id = v_ledger.id;
    v_ledger_n := v_ledger_n + 1;
  END LOOP;

  -- 3) Player stats + result submissions
  IF to_regclass('public.competition_match_player_stats') IS NOT NULL THEN
    DELETE FROM public.competition_match_player_stats WHERE fixture_id = v_fid;
    GET DIAGNOSTICS v_stats = ROW_COUNT;
  END IF;

  IF to_regclass('public.competition_result_submissions') IS NOT NULL THEN
    DELETE FROM public.competition_result_submissions WHERE fixture_id = v_fid;
    GET DIAGNOSTICS v_subs = ROW_COUNT;
  END IF;

  -- 4) Discipline from this fixture
  IF to_regclass('public.competition_player_suspension_matches') IS NOT NULL THEN
    DELETE FROM public.competition_player_suspension_matches
    WHERE fixture_id = v_fid;
  END IF;
  IF to_regclass('public.competition_player_suspensions') IS NOT NULL THEN
    DELETE FROM public.competition_player_suspensions
    WHERE source_fixture_id = v_fid;
    GET DIAGNOSTICS v_susp = ROW_COUNT;
  END IF;

  IF to_regclass('public.competition_player_injury_fixtures') IS NOT NULL THEN
    DELETE FROM public.competition_player_injury_fixtures
    WHERE fixture_id = v_fid;
  END IF;
  IF to_regclass('public.competition_player_injuries') IS NOT NULL THEN
    UPDATE public.competition_player_injuries i
    SET status = 'cancelled'
    WHERE i.source_fixture_id = v_fid
      AND i.status = 'active';
    GET DIAGNOSTICS v_inj = ROW_COUNT;
  END IF;

  IF to_regprocedure('public.competition_resync_pending_suspensions(bigint, text)') IS NOT NULL THEN
    PERFORM public.competition_resync_pending_suspensions(v_f.season_id, v_home);
    PERFORM public.competition_resync_pending_suspensions(v_f.season_id, v_away);
  END IF;

  -- 5) Match-fitness tick for this fixture (streak rebuilt below)
  IF to_regclass('public.competition_fixture_match_fitness_tick') IS NOT NULL THEN
    DELETE FROM public.competition_fixture_match_fitness_tick
    WHERE fixture_id = v_fid;
  END IF;

  -- 6) Fixture back to scheduled / unplayed
  UPDATE public.competition_fixtures
  SET
    status = 'scheduled',
    home_goals = NULL,
    away_goals = NULL,
    is_forfeit = false,
    forfeit_loser_club = NULL,
    is_void = false
  WHERE id = v_fid;

  -- 7) Schedule wipe → unscheduled (September catch-up rearrange)
  DELETE FROM public.competition_fixture_schedule_proposal WHERE fixture_id = v_fid;
  DELETE FROM public.competition_fixture_checkin WHERE fixture_id = v_fid;

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

  -- 8) Archive schedule / result inbox noise
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
      'match_no_show',
      'result_to_confirm',
      'result_submitted',
      'result_confirmed'
    );
  GET DIAGNOSTICS v_n = ROW_COUNT;

  -- 9) Rebuild fitness for both clubs (needs admin_match_fitness_rebuild_streaks)
  IF to_regprocedure('public.admin_match_fitness_rebuild_streaks(bigint, text)') IS NOT NULL THEN
    v_fit := public.admin_match_fitness_rebuild_streaks(v_f.season_id, v_home);
    v_fit := public.admin_match_fitness_rebuild_streaks(v_f.season_id, v_away);
  END IF;

  RAISE NOTICE
    'SOA–COR MD1 wipe fid=% status→scheduled unscheduled | stats=% subs=% ledger=% susp=% inj_cancelled=% inbox=% video=% fitness=%',
    v_fid, v_stats, v_subs, v_ledger_n, v_susp, v_inj, v_n, v_video, v_fit;
  RAISE NOTICE
    'Staff exemption: August MD1 may be rearranged/played in September as catch-up — no fine intended from this wipe.';
END;
$$;

-- Verify
SELECT
  f.id,
  f.status AS fixture_status,
  f.home_club_short_name,
  f.away_club_short_name,
  f.matchday,
  f.home_goals,
  f.away_goals,
  f.is_forfeit,
  sch.status AS schedule_status,
  sch.agreed_kickoff_at,
  (SELECT count(*) FROM public.competition_result_submissions s WHERE s.fixture_id = f.id) AS submissions,
  (SELECT count(*) FROM public.competition_match_player_stats m WHERE m.fixture_id = f.id) AS stats,
  (SELECT count(*) FROM public.fixture_match_videos v WHERE v.fixture_id = f.id) AS videos,
  (SELECT count(*) FROM public.fixture_match_video_pending pv WHERE pv.fixture_id = f.id) AS pending_videos,
  (SELECT count(*) FROM public.competition_finance_ledger l WHERE l.fixture_id = f.id) AS ledger_rows,
  (SELECT count(*) FROM public.competition_fixture_checkin c WHERE c.fixture_id = f.id) AS checkins
FROM public.competition_fixtures f
LEFT JOIN public.competition_fixture_schedule sch ON sch.fixture_id = f.id
WHERE f.id = 8966;
