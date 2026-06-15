-- Audit: GPDB player pool per international nation (for nation selection / call-ups)
-- Run in Supabase SQL Editor. Requires competition_international.sql + international_callup_gpdb.sql
--
-- Callable = Players.Nation normalizes to international_nations.name OR code
-- (same rule as international_player_matches_nation / GPDB "My nation" filter)

WITH nation_players AS (
  SELECT
    n.code,
    n.name,
    n.seed_rank,
    n.active,
    p."Konami_ID",
    p."Position",
    p."Nation" AS player_nation_label
  FROM public.international_nations n
  LEFT JOIN public."Players" p ON (
    public.international_normalize_nation_label(p."Nation")
      = public.international_normalize_nation_label(n.name)
    OR public.international_normalize_nation_label(p."Nation")
      = public.international_normalize_nation_label(n.code)
  )
  WHERE n.active = true
),
counts AS (
  SELECT
    code,
    name,
    seed_rank,
    count("Konami_ID")::integer AS players_total,
    count("Konami_ID") FILTER (
      WHERE upper(btrim(coalesce("Position", ''))) = 'GK'
    )::integer AS goalkeepers
  FROM nation_players
  GROUP BY code, name, seed_rank
)
SELECT
  code,
  name,
  seed_rank,
  players_total,
  goalkeepers,
  CASE
    WHEN players_total >= 24 AND goalkeepers >= 2 THEN 'ok'
    WHEN players_total >= 23 AND goalkeepers >= 2 THEN 'tight'
    WHEN players_total = 0 THEN 'no_gpdb_match'
    ELSE 'short'
  END AS pool_status
FROM counts
ORDER BY players_total ASC, seed_rank ASC;

-- Summary only
-- SELECT
--   count(*) FILTER (WHERE players_total >= 24 AND goalkeepers >= 2) AS nations_ok_24_2gk,
--   count(*) FILTER (WHERE players_total < 24 OR goalkeepers < 2) AS nations_short,
--   count(*) FILTER (WHERE players_total = 0) AS nations_no_gpdb_match,
--   count(*) AS nations_total
-- FROM counts;

-- Unmatched Players.Nation labels (data hygiene — may be eFootball nations not in the 60, or spelling)
-- SELECT p."Nation", count(*)::integer AS players
-- FROM public."Players" p
-- WHERE btrim(coalesce(p."Nation", '')) <> ''
--   AND NOT EXISTS (
--     SELECT 1
--     FROM public.international_nations n
--     WHERE n.active = true
--       AND (
--         public.international_normalize_nation_label(p."Nation")
--           = public.international_normalize_nation_label(n.name)
--         OR public.international_normalize_nation_label(p."Nation")
--           = public.international_normalize_nation_label(n.code)
--       )
--   )
-- GROUP BY p."Nation"
-- ORDER BY players DESC, p."Nation";
