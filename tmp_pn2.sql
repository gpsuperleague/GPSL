select * from competition_fixture_play_now_session where fixture_id=9426;

select jobname, command from cron.job where command ilike '%play_now%' or command ilike '%forfeit%' or command ilike '%checkin%';
