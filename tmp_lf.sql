-- Live forfeit: any delete or reset?
select
  position('DELETE FROM public.competition_fixture_checkin' in pg_get_functiondef('public.fixture_try_checkin_forfeit(bigint)'::regprocedure)) as del_pos,
  position('reset_to_unscheduled' in pg_get_functiondef('public.fixture_try_checkin_forfeit(bigint)'::regprocedure)) as reset_pos,
  position('play_now' in pg_get_functiondef('public.fixture_try_checkin_forfeit(bigint)'::regprocedure)) as play_now_pos,
  position('agreed_kickoff_at' in pg_get_functiondef('public.fixture_try_checkin_forfeit(bigint)'::regprocedure)) as ko_pos;
