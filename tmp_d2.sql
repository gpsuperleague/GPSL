-- Live forfeit function: does it still delete checkins?
select
  position('DELETE FROM public.competition_fixture_checkin' in pg_get_functiondef('public.fixture_try_checkin_forfeit(bigint)'::regprocedure)) > 0 as deletes_checkins,
  position('both_miss' in pg_get_functiondef('public.fixture_try_checkin_forfeit(bigint)'::regprocedure)) > 0 as has_both_miss;
