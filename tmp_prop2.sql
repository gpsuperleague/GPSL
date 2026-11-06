select id, fixture_id,
  created_at at time zone 'Europe/London' as uk,
  kickoff_at at time zone 'Europe/London' as uk_ko,
  status, proposed_by_club_short_name
from competition_fixture_schedule_proposal
where fixture_id = 9426
order by created_at;
