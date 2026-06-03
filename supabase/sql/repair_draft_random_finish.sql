-- One-off: set missing draft_random_finish_time (6:50:00–6:59:58 UK after draft start).
-- Run in Supabase SQL Editor if a draft enabled without a secret finish (bidding ran until 6:59:59 UI only).

UPDATE global_settings
SET draft_random_finish_time =
  draft_auction_start_time
  + interval '23 hours 50 minutes'
  + make_interval(secs => floor(random() * 599)::int)
WHERE id = 1
  AND COALESCE(draft_auction_enabled, false)
  AND draft_auction_start_time IS NOT NULL
  AND draft_random_finish_time IS NULL;
