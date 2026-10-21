WITH season AS (
  SELECT id FROM competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
),
clubs AS (
  SELECT * FROM (VALUES
    ('CAP', 'vardy_np', 'Asia/Calcutta'),
    ('CRV', 'Matjaz', 'Asia/Bangkok')
  ) AS t(short, tag, tz)
),
slots AS (
  SELECT s.club_short_name, s.iso_dow, s.slot_minute,
         (s.slot_minute / 60)::int AS local_hour,
         (s.slot_minute % 60)::int AS local_min,
         c.tz, c.tag
  FROM club_owner_availability_slot s
  JOIN season se ON se.id = s.season_id
  JOIN clubs c ON c.short = s.club_short_name
  WHERE s.iso_dow = 5  -- Friday
)
SELECT club_short_name, tag, tz, iso_dow,
       lpad(local_hour::text, 2, '0') || ':' || lpad(local_min::text, 2, '0') AS local_time,
       slot_minute
FROM slots
ORDER BY club_short_name, slot_minute;
