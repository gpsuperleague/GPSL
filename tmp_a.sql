-- Any schedule history / audit around 9426 between 19:20 and 19:50?
select table_name from information_schema.tables
where table_schema='public' and (
  table_name ilike '%schedule%hist%' or table_name ilike '%checkin%audit%'
  or table_name ilike '%fixture%event%'
) order by 1;
