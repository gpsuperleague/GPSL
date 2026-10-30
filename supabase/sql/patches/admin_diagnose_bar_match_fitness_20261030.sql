-- Diagnose Barcelona match-fitness streak vs season appearances
-- UI "0/4" = consecutive fitness units in current band (start=1, sub=0.5),
-- NOT season appearances. If consecutive_appearances is 0, meter shows 0/4
-- even when the player has 3 apps in season stats.

WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
),
bar_apps AS (
  SELECT
    m.player_id,
    count(*) FILTER (WHERE m.appeared) AS apps,
    count(*) FILTER (WHERE m.started) AS starts,
    count(*) FILTER (WHERE m.subbed_on AND NOT coalesce(m.started, false)) AS subs,
    count(DISTINCT m.fixture_id) FILTER (WHERE m.appeared) AS fixtures_appeared,
    array_agg(DISTINCT upper(btrim(m.club_short_name))) AS club_names_on_stats
  FROM public.competition_match_player_stats m
  JOIN public.competition_fixtures f ON f.id = m.fixture_id
  JOIN cur ON cur.season_id = f.season_id
  WHERE f.status = 'played'
    AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
    AND (
      upper(btrim(m.club_short_name)) = 'BAR'
      OR upper(btrim(f.home_club_short_name)) = 'BAR'
      OR upper(btrim(f.away_club_short_name)) = 'BAR'
    )
  GROUP BY m.player_id
)
SELECT
  'fitness_vs_apps' AS section,
  a.player_id,
  p."Name" AS player_name,
  p."Position",
  a.apps,
  a.starts,
  a.subs,
  a.club_names_on_stats,
  f.consecutive_appearances,
  f.fitness_level,
  f.club_short_name AS fitness_club,
  f.updated_at AS fitness_updated_at
FROM bar_apps a
LEFT JOIN cur ON true
LEFT JOIN public.competition_player_match_fitness f
  ON f.season_id = cur.season_id
 AND f.player_id = a.player_id
LEFT JOIN public."Players" p ON p."Konami_ID"::text = a.player_id
ORDER BY a.apps DESC, p."Name"
LIMIT 40;

WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
)
SELECT
  'bar_played_fixtures' AS section,
  f.id,
  f.gpsl_month,
  f.matchday,
  f.competition_type,
  f.home_club_short_name,
  f.away_club_short_name,
  f.status,
  f.admin_replay_reset_at,
  EXISTS (
    SELECT 1 FROM public.competition_fixture_match_fitness_tick t
    WHERE t.fixture_id = f.id AND upper(btrim(t.club_short_name)) = 'BAR'
  ) AS fitness_tick_bar,
  (
    SELECT count(*) FROM public.competition_match_player_stats m
    WHERE m.fixture_id = f.id
      AND upper(btrim(m.club_short_name)) = 'BAR'
      AND m.appeared
  ) AS bar_appeared_rows,
  (
    SELECT count(*) FROM public.competition_match_player_stats m
    WHERE m.fixture_id = f.id
      AND upper(btrim(m.club_short_name)) = 'BAR'
      AND m.started
  ) AS bar_started_rows
FROM public.competition_fixtures f
JOIN cur ON cur.season_id = f.season_id
WHERE f.status = 'played'
  AND coalesce(f.competition_type, 'league') IN ('league', 'cup')
  AND (
    upper(btrim(f.home_club_short_name)) = 'BAR'
    OR upper(btrim(f.away_club_short_name)) = 'BAR'
  )
ORDER BY public.competition_gpsl_month_sort(f.gpsl_month), f.matchday, f.id;

SELECT
  'fitness_tick_orphans' AS section,
  t.fixture_id,
  t.club_short_name,
  t.ticked_at,
  f.status,
  f.gpsl_month
FROM public.competition_fixture_match_fitness_tick t
JOIN public.competition_fixtures f ON f.id = t.fixture_id
WHERE upper(btrim(t.club_short_name)) = 'BAR'
ORDER BY t.ticked_at DESC NULLS LAST
LIMIT 30;
