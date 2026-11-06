-- Any check-in related tables / audit
select table_name from information_schema.tables
where table_schema='public' and (
  table_name ilike '%checkin%' or table_name ilike '%check_in%' or table_name ilike '%matchday%check%'
) order by 1;
