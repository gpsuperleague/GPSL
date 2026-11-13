-- Super League MD10 Atalanta 3-2 Platense (fixture 9056).
-- Illegal formation, then the Atalanta owner left in October.
-- Wipe the played result, then apply the vacant-club month-lock forfeit: 0-3 to Platense.

DO $award$
DECLARE
  v_f public.competition_fixtures%ROWTYPE;
  v_reset jsonb;
  v_award jsonb;
BEGIN
  PERFORM set_config('statement_timeout', '180s', true);

  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = 9056
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture 9056 not found';
  END IF;

  IF v_f.competition_type IS DISTINCT FROM 'league'
     OR v_f.division IS DISTINCT FROM 'superleague'
     OR v_f.matchday IS DISTINCT FROM 10
     OR v_f.gpsl_month IS DISTINCT FROM 'october'
     OR upper(v_f.home_club_short_name) IS DISTINCT FROM 'ATA'
     OR upper(v_f.away_club_short_name) IS DISTINCT FROM 'CAP'
     OR v_f.status IS DISTINCT FROM 'played'
     OR v_f.home_goals IS DISTINCT FROM 3
     OR v_f.away_goals IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION
      'Fixture 9056 is not the played October SL MD10 Atalanta 3-2 Platense';
  END IF;

  IF NOT public.competition_club_is_fixture_inactive('ATA', v_f.season_id)
     OR public.competition_club_is_fixture_inactive('CAP', v_f.season_id) THEN
    RAISE EXCEPTION 'Atalanta must be the inactive club and Platense the active one';
  END IF;

  v_reset := public.admin_fixture_reset_for_replay(
    9056,
    'Illegal formation, owner left the same month. Result wiped so the October lock vacant forfeit can stand.',
    'RESET FIXTURE REPLAY'
  );

  v_award := public.competition_apply_vacant_fixture_result_fast(9056);

  IF coalesce((v_award->>'ok')::boolean, false) IS NOT TRUE
     OR v_award->>'result' IS DISTINCT FROM 'walkover'
     OR v_award->>'winner' IS DISTINCT FROM 'CAP'
     OR v_award->>'loser' IS DISTINCT FROM 'ATA' THEN
    RAISE EXCEPTION 'Vacant forfeit did not award Platense the win: %', v_award;
  END IF;
END
$award$;

SELECT jsonb_build_object(
  'id', f.id,
  'status', f.status,
  'home', f.home_club_short_name,
  'away', f.away_club_short_name,
  'home_goals', f.home_goals,
  'away_goals', f.away_goals,
  'forfeit', f.is_forfeit,
  'loser', f.forfeit_loser_club,
  'stats', (SELECT count(*) FROM public.competition_match_player_stats s WHERE s.fixture_id = f.id),
  'videos', (SELECT count(*) FROM public.fixture_match_videos v WHERE v.fixture_id = f.id)
)
FROM public.competition_fixtures f
WHERE f.id = 9056;
