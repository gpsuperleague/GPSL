select id, created_at at time zone 'Europe/London' as uk, event_type, headline, status, metadata
from discord_feed_queue
where metadata::text ilike '%9426%'
   or headline ilike '%Besiktas%'
   or body ilike '%9426%'
order by created_at desc
limit 30;
