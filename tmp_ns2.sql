select table_name from information_schema.tables
where table_schema='public' and (table_name ilike '%no_show%' or table_name ilike '%noshow%' or table_name ilike '%strike%');
