select * from competition_fixture_checkin where fixture_id=9426;

select e.*, f.home_club_short_name, f.away_club_short_name
from competition_fixture_no_show_events e
join competition_fixtures f on f.id=e.fixture_id
where e.fixture_id=9426;

select s.status, s.agreed_kickoff_at, s.play_attempt_count, s.admin_result_unlock_at, s.admin_result_unlock_note,
  s.no_show_club_short_name, s.no_show_kickoff_at, s.updated_at
from competition_fixture_schedule s where s.fixture_id=9426;
