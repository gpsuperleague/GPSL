-- =============================================================================
-- GPSL Central Bank — league-readable views (ledger + all club loans)
-- Run after central_bank_phase1.sql and central_bank_loans.sql
-- =============================================================================

DROP VIEW IF EXISTS public.bank_ledger_public;

CREATE VIEW public.bank_ledger_public
WITH (security_invoker = false)
AS
SELECT
  bl.id,
  bl.entry_type,
  bl.amount,
  bl.description,
  bl.club_short_name,
  c."Club" AS club_name,
  bl.club_ledger_id,
  bl.metadata,
  bl.created_at
FROM public.bank_ledger bl
LEFT JOIN public."Clubs" c ON c."ShortName" = bl.club_short_name;

GRANT SELECT ON public.bank_ledger_public TO authenticated;

DROP VIEW IF EXISTS public.club_loans_league_public;

CREATE VIEW public.club_loans_league_public
WITH (security_invoker = false)
AS
SELECT
  l.id,
  l.club_short_name,
  c."Club" AS club_name,
  l.season_id,
  l.principal_drawn,
  l.outstanding_principal,
  l.interest_rate_pct,
  l.status,
  l.created_at,
  l.updated_at,
  l.closed_at
FROM public.club_loans l
JOIN public."Clubs" c ON c."ShortName" = l.club_short_name;

GRANT SELECT ON public.club_loans_league_public TO authenticated;

NOTIFY pgrst, 'reload schema';
