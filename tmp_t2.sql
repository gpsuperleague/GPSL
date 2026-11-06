select table_name from information_schema.tables
where table_schema='public'
  and (table_name ilike '%profile%' or table_name ilike '%user%' or table_name='Clubs')
order by 1
limit 40;
