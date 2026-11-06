select column_name from information_schema.columns
where table_schema='public' and table_name='competition_fixture_no_show_events'
order by ordinal_position;
