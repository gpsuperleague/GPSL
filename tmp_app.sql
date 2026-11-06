-- Read match_schedule_apply_club_noshow for side effects
select position('checkin' in pg_get_functiondef('public.match_schedule_apply_club_noshow(bigint,text,timestamptz,integer,boolean)'::regprocedure)) as pos;
