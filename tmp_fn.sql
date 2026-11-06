-- Check-in RPC / audit: any log of checkin for 9426?
select proname from pg_proc
where pronamespace='public'::regnamespace
  and (proname ilike '%checkin%' or proname ilike '%check_in%')
order by 1;
