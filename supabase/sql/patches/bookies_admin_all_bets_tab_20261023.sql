-- =============================================================================
-- Bookies: My slips = own only; admin all-bets view for All slips tab
-- =============================================================================
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

DROP VIEW IF EXISTS public.bookies_admin_bets_public;

CREATE VIEW public.bookies_admin_bets_public
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
  s.label AS selection_label,
  coalesce(
    nullif(btrim(r.owner_tag), ''),
    nullif(btrim(c.owner), ''),
    left(b.owner_id::text, 8)
  ) AS bettor_tag
FROM public.bookies_bets b
JOIN public.bookies_markets m ON m.id = b.market_id
JOIN public.bookies_selections s ON s.id = b.selection_id
LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = b.owner_id
LEFT JOIN public."Clubs" c ON c.owner_id = b.owner_id
WHERE public.is_gpsl_admin();

GRANT SELECT ON public.bookies_admin_bets_public TO authenticated;

NOTIFY pgrst, 'reload schema';
