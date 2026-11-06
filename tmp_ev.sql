select created_at at time zone 'Europe/London' as uk,
  event_type, actor_club_short_name, payload
from match_schedule_event
where fixture_id = 9426
  and created_at between '2026-11-05 18:00:00+00' and '2026-11-05 21:00:00+00'
order by created_at;
