-- =============================================================================
-- Special auction — list bids (all clubs after reveal; own bid only during LUB)
-- Run once after special_auctions.sql
-- =============================================================================

CREATE OR REPLACE FUNCTION public.special_auction_list_bids(p_auction_id bigint)
RETURNS SETOF public.special_auction_bids
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_auction public.special_auctions%rowtype;
  v_club text := public.my_club_shortname();
BEGIN
  SELECT * INTO v_auction
  FROM public.special_auctions
  WHERE id = p_auction_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF public.is_gpsl_admin()
     OR v_auction.status IN ('revealed', 'settled')
     OR (v_auction.auction_type = 'snap' AND v_auction.status IN ('scheduled', 'active')) THEN
    RETURN QUERY
    SELECT b.*
    FROM public.special_auction_bids b
    WHERE b.auction_id = p_auction_id
    ORDER BY b.bid_amount ASC, b.club_id ASC;
    RETURN;
  END IF;

  IF v_club IS NULL OR btrim(v_club) = '' THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT b.*
  FROM public.special_auction_bids b
  WHERE b.auction_id = p_auction_id
    AND b.club_id = v_club;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.special_auction_list_bids(bigint) TO authenticated;

COMMENT ON FUNCTION public.special_auction_list_bids(bigint) IS
  'Owner bid list: all bids after LUB reveal/settle (or snap while live); secret LUB phase returns own bid only.';
