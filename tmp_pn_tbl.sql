select table_name from information_schema.tables
where table_schema='public' and table_name ilike '%play_now%';
select * from competition_fixture_play_now_session where fixture_id = 9426;
