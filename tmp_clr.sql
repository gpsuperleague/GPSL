-- match_schedule_clear_no_show and bump defs for checkin delete
select left(pg_get_functiondef('public.match_schedule_clear_no_show(bigint)'::regprocedure), 1500);
