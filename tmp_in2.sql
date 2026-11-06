-- Inbox: did BES get a site check-in confirmation?
select id, message_type, title, left(body,120) as body, created_at
from competition_inbox
where recipient_club_short_name='BES'
  and created_at between '2026-11-05 19:15:00+00' and '2026-11-05 19:50:00+00'
order by created_at;
