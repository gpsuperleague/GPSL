-- =============================================================================
-- Bookies: My slips = own bets only (even for GPSL admins) — 2026-10-23
-- =============================================================================
-- Prefer also running bookies_admin_all_bets_tab_20261023.sql (includes this
-- view plus bookies_admin_bets_public for the All slips tab).
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
