-- Discord feed / queue for this check-in embed
select table_name from information_schema.tables
where table_schema='public' and (
  table_name ilike '%discord%feed%' or table_name ilike '%discord%queue%'
  or table_name ilike '%discord%checkin%'
) order by 1;
