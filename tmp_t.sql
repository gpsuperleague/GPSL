select table_name from information_schema.tables
where table_schema='public'
  and (table_name ilike '%schedule%' or table_name ilike '%checkin%' or table_name ilike '%forfeit%' or table_name ilike '%audit%')
order by 1;
