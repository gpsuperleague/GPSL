-- =============================================================================
-- Side-by-side availability: Jubilo Iwata (JUB) vs Juventus (JUV) in UK time
-- Find the open schedule fixture, dump own / opp / mutual slots + near pairs.
-- =============================================================================

WITH fx AS (
  SELECT f.id, f.gpsl_month, f.home_club_short_name, f.away_club_short_name, f.matchday
  FROM public.competition_fixtures f
  JOIN public.competition_seasons s ON s.id = f.season_id AND s.is_current
  WHERE f.home_club_short_name = 'JUB'
    AND f.away_club_short_name = 'JUV'
    AND f.status = 'scheduled'
  ORDER BY f.matchday NULLS LAST, f.id
  LIMIT 1
)
SELECT
  fx.id AS fixture_id,
  fx.matchday,
  fx.gpsl_month,
  fx.home_club_short_name AS home,
  fx.away_club_short_name AS away,
  public.match_schedule_club_timezone(fx.home_club_short_name) AS home_tz,
  public.match_schedule_club_timezone(fx.away_club_short_name) AS away_tz
FROM fx;

-- All home (JUB) window slots in UK
WITH fx AS (
  SELECT f.id
  FROM public.competition_fixtures f
  JOIN public.competition_seasons s ON s.id = f.season_id AND s.is_current
  WHERE f.home_club_short_name = 'JUB'
    AND f.away_club_short_name = 'JUV'
    AND f.status = 'scheduled'
  ORDER BY f.matchday NULLS LAST, f.id
  LIMIT 1
)
SELECT
  'JUB (home)' AS club,
  to_char(h.kickoff_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') AS uk_local,
  h.kickoff_at AS utc
FROM fx
CROSS JOIN LATERAL public.match_schedule_club_window_slots(fx.id, 'JUB') h
ORDER BY h.kickoff_at;

-- All away (JUV) window slots in UK
WITH fx AS (
  SELECT f.id
  FROM public.competition_fixtures f
  JOIN public.competition_seasons s ON s.id = f.season_id AND s.is_current
  WHERE f.home_club_short_name = 'JUB'
    AND f.away_club_short_name = 'JUV'
    AND f.status = 'scheduled'
  ORDER BY f.matchday NULLS LAST, f.id
  LIMIT 1
)
SELECT
  'JUV (away)' AS club,
  to_char(a.kickoff_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') AS uk_local,
  a.kickoff_at AS utc
FROM fx
CROSS JOIN LATERAL public.match_schedule_club_window_slots(fx.id, 'JUV') a
ORDER BY a.kickoff_at;

-- Side-by-side synced on UK clock (full outer join of UK minute keys)
WITH fx AS (
  SELECT f.id
  FROM public.competition_fixtures f
  JOIN public.competition_seasons s ON s.id = f.season_id AND s.is_current
  WHERE f.home_club_short_name = 'JUB'
    AND f.away_club_short_name = 'JUV'
    AND f.status = 'scheduled'
  ORDER BY f.matchday NULLS LAST, f.id
  LIMIT 1
),
jub AS (
  SELECT
    h.kickoff_at,
    date_trunc('minute', h.kickoff_at AT TIME ZONE 'Europe/London') AS uk_min,
    to_char(h.kickoff_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') AS uk_label
  FROM fx
  CROSS JOIN LATERAL public.match_schedule_club_window_slots(fx.id, 'JUB') h
),
juv AS (
  SELECT
    a.kickoff_at,
    date_trunc('minute', a.kickoff_at AT TIME ZONE 'Europe/London') AS uk_min,
    to_char(a.kickoff_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') AS uk_label
  FROM fx
  CROSS JOIN LATERAL public.match_schedule_club_window_slots(fx.id, 'JUV') a
),
keys AS (
  SELECT uk_min FROM jub
  UNION
  SELECT uk_min FROM juv
)
SELECT
  to_char(k.uk_min, 'Dy DD Mon HH24:MI') AS uk_time,
  CASE WHEN j1.uk_min IS NOT NULL THEN 'YES' ELSE '' END AS jub_free,
  CASE WHEN j2.uk_min IS NOT NULL THEN 'YES' ELSE '' END AS juv_free,
  CASE
    WHEN j1.uk_min IS NOT NULL AND j2.uk_min IS NOT NULL THEN 'EXACT MATCH'
    WHEN j1.uk_min IS NOT NULL THEN 'JUB only'
    WHEN j2.uk_min IS NOT NULL THEN 'JUV only'
  END AS status
FROM keys k
LEFT JOIN jub j1 ON j1.uk_min = k.uk_min
LEFT JOIN juv j2 ON j2.uk_min = k.uk_min
ORDER BY k.uk_min;

-- Near pairs under 2h (candidates for compromise midpoints)
WITH fx AS (
  SELECT f.id
  FROM public.competition_fixtures f
  JOIN public.competition_seasons s ON s.id = f.season_id AND s.is_current
  WHERE f.home_club_short_name = 'JUB'
    AND f.away_club_short_name = 'JUV'
    AND f.status = 'scheduled'
  ORDER BY f.matchday NULLS LAST, f.id
  LIMIT 1
),
jub AS (
  SELECT h.kickoff_at
  FROM fx
  CROSS JOIN LATERAL public.match_schedule_club_window_slots(fx.id, 'JUB') h
),
juv AS (
  SELECT a.kickoff_at
  FROM fx
  CROSS JOIN LATERAL public.match_schedule_club_window_slots(fx.id, 'JUV') a
),
pairs AS (
  SELECT
    j.kickoff_at AS jub_at,
    v.kickoff_at AS juv_at,
    abs(extract(epoch FROM (j.kickoff_at - v.kickoff_at))) AS gap_sec,
    j.kickoff_at + ((v.kickoff_at - j.kickoff_at) / 2) AS mid_raw
  FROM jub j
  CROSS JOIN juv v
  WHERE abs(extract(epoch FROM (j.kickoff_at - v.kickoff_at))) > 0
    AND abs(extract(epoch FROM (j.kickoff_at - v.kickoff_at))) < 7200
),
snapped AS (
  SELECT
    p.*,
    (
      (
        date_trunc('hour', p.mid_raw AT TIME ZONE 'Europe/London')
        + CASE
            WHEN EXTRACT(MINUTE FROM (p.mid_raw AT TIME ZONE 'Europe/London')) >= 30
              THEN interval '30 minutes'
            ELSE interval '0'
          END
      ) AT TIME ZONE 'Europe/London'
    ) AS mid_snap
  FROM pairs p
)
SELECT
  to_char(jub_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') AS jub_uk,
  to_char(juv_at AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') AS juv_uk,
  round(gap_sec / 60.0) AS gap_mins,
  to_char(mid_snap AT TIME ZONE 'Europe/London', 'Dy DD Mon HH24:MI') AS midpoint_uk,
  EXISTS (SELECT 1 FROM jub x WHERE x.kickoff_at = mid_snap)
    OR EXISTS (SELECT 1 FROM juv x WHERE x.kickoff_at = mid_snap)
    AS midpoint_already_on_someone
FROM snapped
ORDER BY jub_at, gap_mins
LIMIT 80;

-- Counts + how many near pairs yield a *novel* midpoint (not on either calendar)
WITH fx AS (
  SELECT f.id
  FROM public.competition_fixtures f
  JOIN public.competition_seasons s ON s.id = f.season_id AND s.is_current
  WHERE f.home_club_short_name = 'JUB'
    AND f.away_club_short_name = 'JUV'
    AND f.status = 'scheduled'
  ORDER BY f.matchday NULLS LAST, f.id
  LIMIT 1
),
jub AS (
  SELECT h.kickoff_at FROM fx
  CROSS JOIN LATERAL public.match_schedule_club_window_slots(fx.id, 'JUB') h
),
juv AS (
  SELECT a.kickoff_at FROM fx
  CROSS JOIN LATERAL public.match_schedule_club_window_slots(fx.id, 'JUV') a
),
mutual AS (
  SELECT j.kickoff_at FROM jub j
  JOIN juv v ON v.kickoff_at = j.kickoff_at
),
jub_only AS (
  SELECT j.kickoff_at FROM jub j
  WHERE NOT EXISTS (SELECT 1 FROM juv v WHERE v.kickoff_at = j.kickoff_at)
),
juv_only AS (
  SELECT v.kickoff_at FROM juv v
  WHERE NOT EXISTS (SELECT 1 FROM jub j WHERE j.kickoff_at = v.kickoff_at)
),
novel AS (
  SELECT DISTINCT
    (
      (
        date_trunc('hour', mid_raw AT TIME ZONE 'Europe/London')
        + CASE
            WHEN EXTRACT(MINUTE FROM (mid_raw AT TIME ZONE 'Europe/London')) >= 30
              THEN interval '30 minutes'
            ELSE interval '0'
          END
      ) AT TIME ZONE 'Europe/London'
    ) AS mid_snap
  FROM (
    SELECT jo.kickoff_at + ((vo.kickoff_at - jo.kickoff_at) / 2) AS mid_raw
    FROM jub_only jo
    CROSS JOIN juv_only vo
    WHERE abs(extract(epoch FROM (jo.kickoff_at - vo.kickoff_at))) > 0
      AND abs(extract(epoch FROM (jo.kickoff_at - vo.kickoff_at))) < 7200
  ) m
)
SELECT
  (SELECT count(*) FROM jub) AS jub_slots,
  (SELECT count(*) FROM juv) AS juv_slots,
  (SELECT count(*) FROM mutual) AS exact_mutual,
  (SELECT count(*) FROM jub_only) AS jub_only,
  (SELECT count(*) FROM juv_only) AS juv_only,
  (
    SELECT count(*) FROM jub_only jo
    CROSS JOIN juv_only vo
    WHERE abs(extract(epoch FROM (jo.kickoff_at - vo.kickoff_at))) > 0
      AND abs(extract(epoch FROM (jo.kickoff_at - vo.kickoff_at))) < 7200
  ) AS exclusive_near_pairs_under_2h,
  (
    SELECT count(*) FROM novel n
    WHERE NOT EXISTS (SELECT 1 FROM jub j WHERE j.kickoff_at = n.mid_snap)
      AND NOT EXISTS (SELECT 1 FROM juv v WHERE v.kickoff_at = n.mid_snap)
  ) AS novel_compromise_midpoints;
