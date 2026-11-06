-- fixture_check_in: does it insert then discord? Read insert part
select substring(pg_get_functiondef('public.fixture_check_in(bigint)'::regprocedure)
  from position('INSERT INTO public.competition_fixture_checkin' in pg_get_functiondef('public.fixture_check_in(bigint)'::regprocedure))
  for 900);
