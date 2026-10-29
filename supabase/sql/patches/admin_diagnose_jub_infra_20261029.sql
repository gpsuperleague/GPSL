-- JUB infrastructure purchase diagnose
WITH cur AS (
  SELECT id, label, status, is_current
  FROM public.competition_seasons
  WHERE is_current
  ORDER BY id DESC
  LIMIT 1
)
SELECT
  cur.id AS season_id,
  cur.label,
  public.club_had_prior_finance_season('JUB', cur.id) AS continuing_flag,
  public.club_has_assignment_infra_purchase('JUB', NULL) AS has_assignment_infra_fn,
  public.club_stadium_infra_purchase_cost('JUB') AS stadium_cost,
  (SELECT balance FROM public."Club_Finances" WHERE club_name = 'JUB') AS live_balance,
  public.club_assignment_finance_display('JUB') AS display_json
FROM cur;

SELECT
  l.id,
  l.season_id,
  s.label,
  s.is_current,
  l.amount,
  l.created_at,
  l.metadata->>'source' AS source,
  l.metadata->>'starting_budget' AS starting_budget,
  l.description
FROM public.competition_finance_ledger l
LEFT JOIN public.competition_seasons s ON s.id = l.season_id
WHERE l.club_short_name = 'JUB'
  AND l.entry_type = 'infra_purchase'
ORDER BY l.created_at;

SELECT
  count(*) AS jub_ledger_rows_public,
  count(*) FILTER (WHERE entry_type = 'infra_purchase') AS jub_infra_in_public
FROM public.competition_finance_ledger_public
WHERE club_short_name = 'JUB';

-- False-continuing sources (expect 0 rows when season id = 1)
SELECT 'archive' AS reason, a.season_id::text, a.season_label::text AS detail
FROM public.competition_club_finance_season_archive a
WHERE a.club_short_name = 'JUB'
  AND a.season_id < (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
UNION ALL
SELECT 'club_seasons', cs.season_id::text, s.label::text
FROM public.competition_club_seasons cs
JOIN public.competition_seasons s ON s.id = cs.season_id
WHERE cs.club_short_name = 'JUB'
  AND cs.season_id < (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1)
UNION ALL
SELECT 'prior_infra', l.season_id::text, l.amount::text
FROM public.competition_finance_ledger l
WHERE l.club_short_name = 'JUB'
  AND l.entry_type = 'infra_purchase'
  AND l.season_id < (SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1);
