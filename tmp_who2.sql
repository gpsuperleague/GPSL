-- When does forfeit get invoked? from fixture_context?
select position('fixture_try_checkin_forfeit' in pg_get_functiondef('public.match_schedule_fixture_context(bigint)'::regprocedure)) > 0 as ctx_calls_forfeit,
  position('fixture_try_checkin_forfeit' in pg_get_functiondef('public.fixture_check_in(bigint)'::regprocedure)) > 0 as checkin_calls_forfeit;
