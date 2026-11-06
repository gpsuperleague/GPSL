select column_name from information_schema.columns
where table_schema='public' and table_name like '%discord%'
order by table_name, ordinal_position;
