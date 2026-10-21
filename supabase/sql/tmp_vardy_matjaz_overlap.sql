WITH params AS (
  -- Next Friday (ISO: Mon=1 … Fri=5) in UK calendar
  SELECT (
    (CURRENT_DATE AT TIME ZONE 'Europe/London')::date
    + ((5 - EXTRACT(ISODOW FROM (CURRENT_DATE AT TIME ZONE 'Europe/London')::date)::int + 7) % 7)
  )::date AS fri_date
),
season AS (
  SELECT id FROM competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
),
clubs AS (
  SELECT * FROM (VALUES
    ('CAP', 'vardy_np', 'Asia/Calcutta'),
    ('CRV', 'Matjaz', 'Asia/Bangkok')
  ) AS t(short, tag, tz)
),
slots AS (
  SELECT c.short, c.tag, c.tz, s.slot_minute,
         make_time((s.slot_minute / 60)::int, (s.slot_minute % 60)::int, 0) AS local_t,
         -- interpret local wall clock on that Friday in owner TZ → timestamptz
         ((p.fri_date + make_time((s.slot_minute / 60)::int, (s.slot_minute % 60)::int, 0))
           AT TIME ZONE c.tz) AS kickoff_utc
  FROM club_owner_availability_slot s
  JOIN season se ON se.id = s.season_id
  JOIN clubs c ON c.short = s.club_short_name
  CROSS JOIN params p
  WHERE s.iso_dow = 5
),
labeled AS (
  SELECT short, tag, tz,
         to_char(local_t, 'HH24:MI') AS local_time,
         to_char(kickoff_utc AT TIME ZONE 'Europe/London', 'HH24:MI') AS uk_time,
         kickoff_utc,
         (EXTRACT(HOUR FROM kickoff_utc AT TIME ZONE 'Europe/London')::int * 60
          + EXTRACT(MINUTE FROM kickoff_utc AT TIME ZONE 'Europe/London')::int) AS uk_minute
  FROM slots
),
overlap AS (
  SELECT a.uk_time, a.uk_minute,
         a.local_time AS vardy_local, b.local_time AS matjaz_local,
         a.kickoff_utc
  FROM labeled a
  JOIN labeled b ON b.short = 'CRV' AND b.uk_minute = a.uk_minute
  WHERE a.short = 'CAP'
)
SELECT 'slots' AS section, short AS club, tag, tz, local_time, uk_time, NULL::text AS other
FROM labeled
UNION ALL
SELECT 'OVERLAP', 'both', NULL, NULL, vardy_local || ' IST', uk_time || ' UK', matjaz_local || ' ICT'
FROM overlap
ORDER BY 1 DESC, 5;
