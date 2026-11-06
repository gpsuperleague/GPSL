-- schedule row
select * from competition_fixture_schedule where fixture_id = 9426;

-- proposals around that evening
select id, fixture_id, created_at at time zone 'Europe/London' as uk_created,
  proposed_kickoff_at at time zone 'Europe/London' as uk_ko,
  status, proposer_club_short_name, accepter_club_short_name
from competition_fixture_schedule_proposal
where fixture_id = 9426
order by created_at desc
limit 20;

-- current checkins
select * from competition_fixture_checkin where fixture_id = 9426;

-- discord queue for this fixture
select id, created_at at time zone 'Europe/London' as uk, kind, status, payload
from discord_outbound_queue
where (payload->>'fixture_id')::bigint = 9426
   or payload::text ilike '%9426%'
order by created_at;
