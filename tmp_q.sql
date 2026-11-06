select id, created_at, status, left(payload::text, 400) as payload
from gpsl_discord_feed_queue
where created_at between '2026-11-05 19:15:00+00' and '2026-11-05 19:55:00+00'
  and (
    payload::text ilike '%9426%'
    or payload::text ilike '%Besiktas%'
    or payload::text ilike '%CHECKED IN%'
    or payload::text ilike '%BES%'
  )
order by created_at
limit 30;
