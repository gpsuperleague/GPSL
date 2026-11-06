select * from competition_fine_applied where fixture_id = 9426;

select id, created_at at time zone 'Europe/London' as uk, message_type, title,
  recipient_club_short_name, left(body,120) as body
from competition_inbox
where fixture_id = 9426
order by created_at desc
limit 20;

select p.oid::regprocedure
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname ilike '%strike%';
