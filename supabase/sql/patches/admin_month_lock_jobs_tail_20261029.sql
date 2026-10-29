SELECT right(pg_get_functiondef(
  'public.competition_run_month_lock_jobs(bigint,boolean,text,text)'::regprocedure
), 1200) AS tail;
