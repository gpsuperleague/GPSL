-- =============================================================================
-- One-shot: SuperLeague MD3 Boca (BOC) vs Omnisports (SOA) — full wipe + replay
-- Requires: admin_fixture_reset_for_replay_20261027.sql
-- Safe-ish re-run. Run in SQL Editor.
-- =============================================================================

DO $$
DECLARE
  v_fid bigint;
  v_out jsonb;
  v_home text;
  v_away text;
BEGIN
  SELECT f.id, f.home_club_short_name, f.away_club_short_name
  INTO v_fid, v_home, v_away
  FROM public.competition_fixtures f
  JOIN public.competition_seasons s ON s.id = f.season_id AND s.is_current
  WHERE f.competition_type = 'league'
    AND f.division = 'superleague'
    AND f.matchday = 3
    AND (
      (upper(f.home_club_short_name) = 'BOC' AND upper(f.away_club_short_name) = 'SOA')
      OR (upper(f.home_club_short_name) = 'SOA' AND upper(f.away_club_short_name) = 'BOC')
    )
  ORDER BY f.id
  LIMIT 1;

  IF v_fid IS NULL THEN
    RAISE EXCEPTION 'No current-season SuperLeague MD3 BOC vs SOA fixture found';
  END IF;

  IF to_regprocedure('public.admin_fixture_reset_for_replay(bigint, text, text)') IS NULL THEN
    RAISE EXCEPTION
      'Missing admin_fixture_reset_for_replay — run admin_fixture_reset_for_replay_20261027.sql first';
  END IF;

  v_out := public.admin_fixture_reset_for_replay(
    v_fid,
    'Boca vs Omnisports MD3 — staff reset for September replay',
    'RESET FIXTURE REPLAY'
  );

  RAISE NOTICE 'Reset fixture % (% vs %) — %', v_fid, v_home, v_away, v_out;
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
WHERE f.competition_type = 'league'
  AND f.division = 'superleague'
  AND f.matchday = 3
  AND (
    (upper(f.home_club_short_name) = 'BOC' AND upper(f.away_club_short_name) = 'SOA')
    OR (upper(f.home_club_short_name) = 'SOA' AND upper(f.away_club_short_name) = 'BOC')
  )
  AND f.season_id = (
    SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
  );
