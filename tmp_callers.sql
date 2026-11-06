select p.proname
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and pg_get_functiondef(p.oid) ilike '%fixture_try_checkin_forfeit%'
order by 1;
