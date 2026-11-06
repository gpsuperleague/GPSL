select * from competition_fine_applied where fixture_id = 9426 order by applied_at;

select id, created_at at time zone 'Europe/London' as uk, message_type, title,
  recipient_club_short_name, dedupe_key
from competition_inbox
where fixture_id = 9426
  and (message_type ilike '%noshow%' or title ilike '%no-show%' or title ilike '%No-show%')
order by created_at;

select fixture_id, play_attempt_count, admin_result_unlock_note, status
from competition_fixture_schedule where fixture_id = 9426;
