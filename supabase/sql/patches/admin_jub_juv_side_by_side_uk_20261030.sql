-- =============================================================================
-- Fixture 9163 — Jubilo vs Juventus side-by-side availability (UK time)
--
-- One result grid only:
--   uk_time | jubilo | juventus | note
-- =============================================================================

WITH jub AS (
  SELECT DISTINCT date_trunc('minute', h.kickoff_at AT TIME ZONE 'Europe/London') AS uk_min
  FROM public.match_schedule_club_window_slots(9163, 'JUB') h
),
juv AS (
  SELECT DISTINCT date_trunc('minute', a.kickoff_at AT TIME ZONE 'Europe/London') AS uk_min
  FROM public.match_schedule_club_window_slots(9163, 'JUV') a
),
keys AS (
  SELECT uk_min FROM jub
  UNION
  SELECT uk_min FROM juv
)
SELECT
  to_char(k.uk_min, 'Dy DD Mon HH24:MI') AS uk_time,
  CASE WHEN j.uk_min IS NOT NULL THEN 'YES' ELSE 'No' END AS jubilo,
  CASE WHEN v.uk_min IS NOT NULL THEN 'YES' ELSE 'No' END AS juventus,
  CASE
    WHEN j.uk_min IS NOT NULL AND v.uk_min IS NOT NULL THEN 'exact match'
    WHEN j.uk_min IS NOT NULL THEN 'Jubilo only'
    WHEN v.uk_min IS NOT NULL THEN 'Juventus only'
  END AS note
FROM keys k
LEFT JOIN jub j ON j.uk_min = k.uk_min
LEFT JOIN juv v ON v.uk_min = k.uk_min
ORDER BY k.uk_min;
