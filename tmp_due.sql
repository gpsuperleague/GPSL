-- Does process_due_checkin call forfeit, and is there a path that wipes checkin before forfeit?
select substring(pg_get_functiondef('public.match_schedule_process_due_checkin_notices()'::regprocedure)
  from 1 for 2000);
