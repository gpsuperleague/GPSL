-- =============================================================================
-- Bookies: My slips = own bets only (even for GPSL admins) — 2026-10-23
-- =============================================================================
-- bookies_my_bets_public used: owner_id = auth.uid() OR is_gpsl_admin()
-- So admins saw every owner's open slips under "My slips" (looked like their
-- own test bets). My slips must always be the logged-in owner's bets only.
-- Safe re-run.
-- =============================================================================

DROP VIEW IF EXISTS public.bookies_my_bets_public;

CREATE VIEW public.bookies_my_bets_public
WITH (security_invoker = true)
AS
SELECT
  b.id,
  b.season_id,
  b.market_id,
  b.selection_id,
  b.owner_id,
  b.club_short_name,
  b.stake,
  b.odds_decimal,
  public.bookies_fractional_odds_label(b.odds_decimal) AS odds_fractional,
  b.potential_return,
  b.status,
  b.placed_at,
  b.settled_at,
  m.market_code,
  m.title AS market_title,
  m.market_kind,
  s.selection_key,
  s.label AS selection_label
FROM public.bookies_bets b
JOIN public.bookies_markets m ON m.id = b.market_id
JOIN public.bookies_selections s ON s.id = b.selection_id
WHERE b.owner_id = auth.uid();

GRANT SELECT ON public.bookies_my_bets_public TO authenticated;

NOTIFY pgrst, 'reload schema';

DO $$
BEGIN
  RAISE NOTICE 'bookies_my_bets_public: own bets only (admin no longer sees all slips here).';
END $$;
