-- Super League MD11 Santos 2-6 Atalanta (fixture 9065).
-- Illegal formation, and Atalanta were vacant shortly after the match in GPSL October.
-- Wipe the played result, then apply the vacant-club month-lock forfeit: 3-0 to Santos.

DO $award$
DECLARE
  v_f public.competition_fixtures%ROWTYPE;
  v_reset jsonb;
  v_award jsonb;
BEGIN
  PERFORM set_config('statement_timeout', '180s', true);

  SELECT * INTO v_f
  FROM public.competition_fixtures
  WHERE id = 9065
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture 9065 not found';
  END IF;

  IF v_f.competition_type IS DISTINCT FROM 'league'
     OR v_f.division IS DISTINCT FROM 'superleague'
     OR v_f.matchday IS DISTINCT FROM 11
     OR v_f.gpsl_month IS DISTINCT FROM 'october'
     OR upper(v_f.home_club_short_name) IS DISTINCT FROM 'SAN'
     OR upper(v_f.away_club_short_name) IS DISTINCT FROM 'ATA'
     OR v_f.status IS DISTINCT FROM 'played'
     OR v_f.home_goals IS DISTINCT FROM 2
     OR v_f.away_goals IS DISTINCT FROM 6 THEN
    RAISE EXCEPTION
      'Fixture 9065 is not the played October SL MD11 Santos 2-6 Atalanta';
  END IF;

  IF public.competition_club_is_fixture_inactive('SAN', v_f.season_id)
     OR NOT public.competition_club_is_fixture_inactive('ATA', v_f.season_id) THEN
    RAISE EXCEPTION 'Santos must be the active club and Atalanta the inactive one';
  END IF;

  v_reset := public.admin_fixture_reset_for_replay(
    9065,
    'Illegal formation. Atalanta vacant shortly after this October match. Result wiped so the October lock vacant forfeit can stand.',
    'RESET FIXTURE REPLAY'
  );

  v_award := public.competition_apply_vacant_fixture_result_fast(9065);

  IF coalesce((v_award->>'ok')::boolean, false) IS NOT TRUE
     OR v_award->>'result' IS DISTINCT FROM 'walkover'
     OR v_award->>'winner' IS DISTINCT FROM 'SAN'
     OR v_award->>'loser' IS DISTINCT FROM 'ATA' THEN
    RAISE EXCEPTION 'Vacant forfeit did not award Santos the win: %', v_award;
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
  'void', f.is_void,
  'stats', (SELECT count(*) FROM public.competition_match_player_stats s WHERE s.fixture_id = f.id),
  'videos', (SELECT count(*) FROM public.fixture_match_videos v WHERE v.fixture_id = f.id),
  'ledger', (
    SELECT count(*) FROM public.competition_finance_ledger l WHERE l.fixture_id = f.id
  )
)
FROM public.competition_fixtures f
WHERE f.id = 9065;
