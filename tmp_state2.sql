select table_name from information_schema.tables
where table_schema='public' and (
  table_name ilike '%club%' or table_name ilike '%owner_inbox%' or table_name ilike '%fine%'
)
order by 1;
