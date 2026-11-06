select column_name from information_schema.columns
where table_schema='public' and table_name='match_schedule_event' order by ordinal_position;
