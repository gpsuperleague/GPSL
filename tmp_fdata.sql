select fixture_id, status, agreed_kickoff_at at time zone 'Europe/London' as uk_ko,
  no_show_club_short_name,
  no_show_kickoff_at at time zone 'Europe/London' as uk_noshow_ko,
  play_attempt_count, open_play_active, updated_at at time zone 'Europe/London' as uk_upd
from competition_fixture_schedule where fixture_id = 9426;

select * from competition_fixture_checkin where fixture_id = 9426;
