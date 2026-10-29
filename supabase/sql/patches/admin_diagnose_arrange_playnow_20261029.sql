SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname='public' AND (
  p.proname ILIKE '%play_now%' OR p.proname ILIKE '%kickoff_is_ten%'
  OR p.proname = 'match_schedule_assert_play_now_kickoff_ok'
)
ORDER BY 1,2;

SELECT
  CASE
    WHEN position('match_schedule_kickoff_is_ten_min_slot' IN def) > 0 THEN '10min'
    WHEN position('match_schedule_kickoff_is_slot' IN def) > 0 THEN '30min_helper'
    ELSE 'unknown'
  END AS play_now_slot_mode,
  (position('interval ''10 minutes''' IN def) > 0
   OR position('10-minute' IN def) > 0) AS mentions_10min
FROM (
  SELECT pg_get_functiondef(p.oid) AS def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname='public' AND p.proname='match_schedule_assert_play_now_kickoff_ok'
  LIMIT 1
) x;
