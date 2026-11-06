select p.proname, pg_get_function_identity_arguments(p.oid)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and pg_get_functiondef(p.oid) ilike '%DELETE FROM public.competition_fixture_checkin%'
  and pg_get_functiondef(p.oid) not ilike '%admin_fixture%'
order by 1;
