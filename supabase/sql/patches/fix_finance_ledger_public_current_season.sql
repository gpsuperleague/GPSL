-- =============================================================================
-- Finances page was blank for fines (and other ledger lines) when the current
-- competition season is setup / preseason — not only status = 'active'.
-- competition_finance_ledger_public now shows all ledger rows for is_current.
-- Run once in Supabase SQL Editor, then refresh Finances.
-- =============================================================================

CREATE OR REPLACE VIEW public.competition_finance_ledger_public
WITH (security_invoker = false)
AS
SELECT
  l.id,
  l.season_id,
  l.fixture_id,
  l.club_short_name,
  c."Club" AS club_name,
  l.entry_type,
  l.amount,
  l.description,
  l.metadata,
  l.created_at,
  f.matchday,
  f.competition_type,
  f.home_club_short_name,
  f.away_club_short_name
FROM public.competition_finance_ledger l
JOIN public."Clubs" c ON c."ShortName" = l.club_short_name
LEFT JOIN public.competition_fixtures f ON f.id = l.fixture_id
JOIN public.competition_seasons s ON s.id = l.season_id
WHERE s.is_current = true;

GRANT SELECT ON public.competition_finance_ledger_public TO authenticated;
GRANT SELECT ON public.competition_finance_ledger_public TO anon;

NOTIFY pgrst, 'reload schema';
