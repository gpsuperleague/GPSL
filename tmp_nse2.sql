select *, created_at at time zone 'Europe/London' as uk
from competition_fixture_no_show_events
where fixture_id = 9426
order by created_at;
