select position('DELETE FROM public.competition_fixture_checkin' in pg_get_functiondef('public.match_schedule_clear_no_show(bigint)'::regprocedure)) > 0 as clear_deletes,
  position('DELETE FROM public.competition_fixture_checkin' in pg_get_functiondef('public.match_schedule_bump_attempt_on_noshow(bigint)'::regprocedure)) > 0 as bump_deletes,
  position('DELETE FROM public.competition_fixture_checkin' in pg_get_functiondef('public.fixture_schedule_propose(bigint,timestamptz)'::regprocedure)) > 0 as propose_deletes;
