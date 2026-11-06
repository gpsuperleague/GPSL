select id, club_short_name, both_miss, action, kickoff_at, created_at
from competition_fixture_no_show_events where fixture_id=9426 order by id;

select s.strike_count, cl."ShortName"
from competition_owner_season_strikes s
join "Clubs" cl on cl.owner_id=s.owner_id
where cl."ShortName" in ('BES','FLA');

select admin_result_unlock_note from competition_fixture_schedule where fixture_id=9426;

select position('overlapped the agreed-KO' in pg_get_functiondef('public.match_schedule_play_now_session_tick(bigint)'::regprocedure)) > 0 as tick_patched;
