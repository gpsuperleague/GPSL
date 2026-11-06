select id, event_type, status, headline, left(coalesce(body,''), 200) as body,
  left(coalesce(metadata::text,''), 300) as meta, created_at, posted_at, dedupe_key
from gpsl_discord_feed_queue
where created_at between '2026-11-05 19:15:00+00' and '2026-11-05 19:55:00+00'
  and (
    coalesce(headline,'') ilike '%check%'
    or coalesce(body,'') ilike '%Besiktas%'
    or coalesce(body,'') ilike '%9426%'
    or coalesce(dedupe_key,'') ilike '%9426%'
    or coalesce(metadata::text,'') ilike '%9426%'
    or coalesce(event_type,'') ilike '%check%'
  )
order by created_at;
