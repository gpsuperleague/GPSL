select id, created_at at time zone 'Europe/London' as uk, event_type, headline, status, metadata
from gpsl_discord_feed_queue
where metadata::text ilike '%9426%'
   or (created_at between '2026-11-05 19:00:00+00' and '2026-11-05 20:30:00+00'
       and (headline ilike '%Besiktas%' or headline ilike '%CHECKED%' or headline ilike '%no-show%' or headline ilike '%no show%' or body ilike '%Flamengo%'))
order by created_at;
