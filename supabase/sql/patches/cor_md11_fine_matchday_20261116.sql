-- Put the Corinthians matchroom fine back on the ledger, with the matchday.
-- The club was already charged. This does not charge again.
-- Safe re-run.

INSERT INTO public.competition_finance_ledger (
  id, season_id, fixture_id, club_short_name, entry_type, amount,
  description, metadata, created_at
) OVERRIDING SYSTEM VALUE
SELECT
  563049,
  1,
  9060,
  'COR',
  'gov_fine_compensation',
  -1500000,
  format(
    'Fine — [NOT SHOWING] Matchroom settings (Home) — Not shown pre-match or in match — MD%s vs %s',
    f.matchday,
    coalesce(public.club_display_name(f.away_club_short_name), f.away_club_short_name)
  ),
  jsonb_build_object(
    'tariff_code', 'matchroom_not_displayed_home',
    'direction', 'fine',
    'category', 'matchday'
  ),
  '2026-11-16 16:56:58.279285+00'::timestamptz
FROM public.competition_fixtures f
WHERE f.id = 9060
  AND NOT EXISTS (
    SELECT 1 FROM public.competition_finance_ledger l WHERE l.id = 563049
  );

UPDATE public.competition_fine_applied a
SET ledger_id = 563049,
    description = l.description
FROM public.competition_finance_ledger l
WHERE a.id = 2432848
  AND l.id = 563049
  AND (
    a.ledger_id IS DISTINCT FROM 563049
    OR a.description IS DISTINCT FROM l.description
  );

SELECT jsonb_build_object(
  'desc', l.description,
  'amount', l.amount,
  'fixture', l.fixture_id,
  'fine_ledger', a.ledger_id
)
FROM public.competition_finance_ledger l
JOIN public.competition_fine_applied a ON a.id = 2432848
WHERE l.id = 563049;
