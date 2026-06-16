-- =============================================================================
-- Club auction — public completed purchases (Season club purchases page)
-- Run after patches/club_auction.sql
-- =============================================================================

DROP VIEW IF EXISTS public.club_auction_purchases_public;

CREATE VIEW public.club_auction_purchases_public
WITH (security_invoker = false)
AS
SELECT
  l.id,
  l.club_short_name,
  c."Club" AS club_name,
  c."Nation" AS nation,
  c."Stadium" AS stadium,
  coalesce(c."Capacity", 0)::int AS capacity,
  l.prestige_rank,
  l.expected_position,
  l.opening_bid,
  l.winning_bid,
  coalesce(
    nullif(btrim(r.owner_tag), ''),
    nullif(btrim(c.owner), '')
  ) AS owner_tag,
  l.updated_at AS settled_at
FROM public."Club_Auction_Listings" l
JOIN public."Clubs" c ON c."ShortName" = l.club_short_name
LEFT JOIN public.gpsl_owner_registry r ON r.owner_id = l.winning_owner_id
WHERE l.transfer_completed = true
  AND l.winning_owner_id IS NOT NULL;

GRANT SELECT ON public.club_auction_purchases_public TO authenticated;
GRANT SELECT ON public.club_auction_purchases_public TO anon;

COMMENT ON VIEW public.club_auction_purchases_public IS
  'Settled club auction wins for the Season club purchases page (read-only).';
