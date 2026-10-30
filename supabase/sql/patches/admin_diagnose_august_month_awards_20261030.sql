-- Diagnose: Owner / Team / Manager of the Month for August (and locked months).
-- Why August can look "missing":
--   • Owner of the Month only shipped 2026-10-22 — after August already locked
--   • Team of the Month jobs are skip-if-already-ran; August admin replay does
--     not clear those job rows, so a stale/empty first pass never retries
--   • Month-lock "awards" stage historically omitted MotM/OotM (motm stage only)
-- Safe read-only.

WITH cur AS (
  SELECT id AS season_id, label
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
),
locked AS (
  SELECT
    c.season_id,
    lower(btrim(c.gpsl_month)) AS gpsl_month,
    c.lock_at,
    c.unlock_at
  FROM public.competition_season_calendar c
  JOIN cur ON cur.season_id = c.season_id
  WHERE c.gpsl_month IS NOT NULL
    AND c.gpsl_month <> 'playoffs'
    AND c.lock_at IS NOT NULL
    AND c.lock_at <= now()
)
SELECT
  'calendar_locks' AS section,
  l.gpsl_month,
  l.lock_at,
  (SELECT count(*) FROM public.competition_fixtures f
    WHERE f.season_id = l.season_id
      AND lower(btrim(f.gpsl_month)) = l.gpsl_month
      AND f.competition_type = 'league'
      AND f.status = 'played') AS league_played,
  (SELECT count(*) FROM public.competition_fixtures f
    WHERE f.season_id = l.season_id
      AND lower(btrim(f.gpsl_month)) = l.gpsl_month
      AND f.admin_replay_reset_at IS NOT NULL) AS still_replay_stamped,
  (SELECT count(*) FROM public.competition_period_team t
    WHERE t.season_id = l.season_id
      AND t.period_kind = 'month'
      AND lower(btrim(t.gpsl_month)) = l.gpsl_month) AS totm_teams,
  (SELECT count(*) FROM public.competition_owner_month_award a
    WHERE a.season_id = l.season_id
      AND lower(btrim(a.gpsl_month)) = l.gpsl_month) AS ootm_awards,
  (SELECT count(*) FROM public.competition_manager_month_award m
    WHERE m.season_id = l.season_id
      AND lower(btrim(m.gpsl_month)) = l.gpsl_month) AS motm_awards
FROM locked l
ORDER BY public.competition_gpsl_month_sort(l.gpsl_month);

WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
)
SELECT
  'august_jobs' AS section,
  j.job_key,
  j.gpsl_month,
  j.ran_at,
  j.result
FROM public.competition_season_calendar_jobs j
JOIN cur ON cur.season_id = j.season_id
WHERE lower(btrim(coalesce(j.gpsl_month, ''))) = 'august'
   OR j.job_key ILIKE '%august%'
ORDER BY j.ran_at NULLS LAST, j.job_key;

WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
)
SELECT
  'august_totm' AS section,
  t.id,
  t.division_scope,
  t.formation_id,
  t.computed_at,
  (SELECT count(*) FROM public.competition_period_team_member m WHERE m.team_id = t.id) AS members
FROM public.competition_period_team t
JOIN cur ON cur.season_id = t.season_id
WHERE t.period_kind = 'month'
  AND lower(btrim(t.gpsl_month)) = 'august'
ORDER BY t.division_scope;

WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
)
SELECT
  'august_ootm' AS section,
  a.division_scope,
  a.owner_tag,
  a.club_short_name,
  a.pts,
  a.detail,
  a.created_at
FROM public.competition_owner_month_award a
JOIN cur ON cur.season_id = a.season_id
WHERE lower(btrim(a.gpsl_month)) = 'august'
ORDER BY a.division_scope;

WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
)
SELECT
  'august_motm' AS section,
  m.manager_name,
  m.club_short_name,
  m.pts,
  m.created_at
FROM public.competition_manager_month_award m
JOIN cur ON cur.season_id = m.season_id
WHERE lower(btrim(m.gpsl_month)) = 'august';

WITH cur AS (
  SELECT id AS season_id
  FROM public.competition_seasons
  WHERE is_current = true
  ORDER BY id DESC
  LIMIT 1
)
SELECT
  'august_player_month_stats' AS section,
  count(*) AS rows_with_apps,
  count(*) FILTER (WHERE appearances >= 2) AS eligible_for_totm
FROM public.competition_player_month_stats_public s
JOIN cur ON cur.season_id = s.season_id
WHERE lower(btrim(s.gpsl_month)) = 'august';
