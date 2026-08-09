-- =============================================================================
-- Club auction stadium cost = Club Database stadium value
--   capacity × ₿1,500  (was × ₿1,000)
--
-- Also drives club_stadium_infra_purchase_cost() via opening_bid_for_capacity.
-- Safe re-run. Refreshes Active listing opening/reserve bids.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.club_auction_opening_bid_for_capacity(p_capacity bigint)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT greatest(coalesce(p_capacity, 0), 0)::numeric * 1500;
$$;

COMMENT ON FUNCTION public.club_auction_opening_bid_for_capacity(bigint) IS
  'Club auction opening bid / stadium cost = capacity × ₿1,500 (same as clubs_database stadium_value).';

DO $$
BEGIN
  COMMENT ON FUNCTION public.club_stadium_infra_purchase_cost(text) IS
    'Stadium infrastructure purchase cost = capacity × ₿1,500 (matches Club Database stadium value).';
EXCEPTION
  WHEN undefined_function THEN NULL;
END $$;

-- Align active listings with the new rate
UPDATE public."Club_Auction_Listings" l
SET opening_bid = public.club_auction_opening_bid_for_capacity(coalesce(c."Capacity", 0)::bigint),
    reserve_price = public.club_auction_opening_bid_for_capacity(coalesce(c."Capacity", 0)::bigint),
    updated_at = now()
FROM public."Clubs" c
WHERE c."ShortName" = l.club_short_name
  AND l.status = 'Active';

NOTIFY pgrst, 'reload schema';

-- Spot-check
SELECT
  l.club_short_name,
  c."Capacity" AS capacity,
  l.opening_bid,
  public.club_auction_opening_bid_for_capacity(coalesce(c."Capacity", 0)::bigint) AS stadium_cost,
  round(coalesce(c."Capacity", 0)::numeric * 1500) AS database_stadium_value
FROM public."Club_Auction_Listings" l
JOIN public."Clubs" c ON c."ShortName" = l.club_short_name
WHERE l.status = 'Active'
ORDER BY l.prestige_rank NULLS LAST, l.club_short_name
LIMIT 20;
