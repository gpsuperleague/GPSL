-- =============================================================================
-- Diagnose: Season 1 infra_purchase missing from Season accounts / Outgoings
--
-- UI strips assignment stadium buys when club_had_prior_finance_season = true.
-- That can fire incorrectly on "Season 1" if leftover lower-id seasons have
-- archives / club_seasons / old infra rows for the same club codes.
-- =============================================================================

WITH cur AS (
  SELECT id, label, status, is_current, started_at, created_at
  FROM public.competition_seasons
  WHERE is_current
  ORDER BY id DESC
  LIMIT 1
)
SELECT
  'current_season' AS section,
  c.id AS season_id,
  c.label,
  c.status,
  c.is_current,
  c.started_at,
  c.created_at
FROM cur c;

-- Any seasons with id < current (false-continuing fuel)
SELECT
  'prior_seasons' AS section,
  s.id,
  s.label,
  s.status,
  s.is_current,
  s.created_at
FROM public.competition_seasons s
CROSS JOIN (
  SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
) cur
WHERE s.id < cur.id
ORDER BY s.id;

-- Sample owned clubs: continuing flag + why + ledger presence
WITH cur AS (
  SELECT id FROM public.competition_seasons WHERE is_current ORDER BY id DESC LIMIT 1
),
clubs AS (
  SELECT c."ShortName" AS club, c."Club" AS club_name, c.owner_id
  FROM public."Clubs" c
  WHERE c.owner_id IS NOT NULL
  ORDER BY c."ShortName"
  LIMIT 40
)
SELECT
  cl.club,
  cl.club_name,
  public.club_had_prior_finance_season(cl.club, cur.id) AS continuing_flag,
  EXISTS (
    SELECT 1 FROM public.competition_club_finance_season_archive a
    WHERE a.club_short_name = cl.club AND a.season_id < cur.id
  ) AS has_prior_archive,
  EXISTS (
    SELECT 1 FROM public.competition_finance_ledger l
    WHERE l.club_short_name = cl.club
      AND l.entry_type = 'infra_purchase'
      AND l.season_id < cur.id
  ) AS has_prior_infra,
  EXISTS (
    SELECT 1 FROM public.competition_club_seasons cs
    WHERE cs.club_short_name = cl.club AND cs.season_id < cur.id
  ) AS has_prior_club_season,
  EXISTS (
    SELECT 1 FROM public.competition_finance_ledger l
    WHERE l.club_short_name = cl.club
      AND l.entry_type = 'infra_purchase'
      AND l.season_id = cur.id
  ) AS infra_on_current_season,
  EXISTS (
    SELECT 1 FROM public.competition_finance_ledger_public p
    WHERE p.club_short_name = cl.club AND p.entry_type = 'infra_purchase'
  ) AS infra_in_public_view,
  (
    SELECT round(sum(l.amount)::numeric, 2)
    FROM public.competition_finance_ledger l
    WHERE l.club_short_name = cl.club AND l.entry_type = 'infra_purchase'
  ) AS infra_total_all_seasons,
  (public.club_assignment_finance_display(cl.club)->>'continuing_club')::boolean AS display_continuing,
  (public.club_assignment_finance_display(cl.club)->>'ledger_posted')::boolean AS display_ledger_posted,
  (public.club_assignment_finance_display(cl.club)->>'show_in_accounts')::boolean AS display_show_in_accounts
FROM clubs cl
CROSS JOIN cur
ORDER BY continuing_flag DESC, cl.club;

-- Raw infra_purchase rows still in DB (any season) — first 80
SELECT
  l.id,
  l.club_short_name,
  l.season_id,
  s.label AS season_label,
  s.is_current,
  l.amount,
  l.created_at,
  l.metadata->>'source' AS source,
  l.metadata->>'starting_budget' AS starting_budget,
  left(l.description, 80) AS description
FROM public.competition_finance_ledger l
LEFT JOIN public.competition_seasons s ON s.id = l.season_id
WHERE l.entry_type = 'infra_purchase'
ORDER BY l.created_at DESC
LIMIT 80;
