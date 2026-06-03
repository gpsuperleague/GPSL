-- Fix direct offers where seller_club_id was saved as full club name (e.g. "Urawa Reds")
-- instead of Clubs.ShortName (e.g. "URD"). Run once in Supabase SQL Editor.
--
-- Example broken row: bid_id 265, Daichi Kamada — seller_club_id "Urawa Reds", should be URD.

UPDATE public."Player_Transfer_Bids" b
SET seller_club_id = c."ShortName"
FROM public."Clubs" c
WHERE b.seller_club_id = c."Club"
  AND b.is_direct = true
  AND b.listing_id IS NULL
  AND lower(coalesce(b.status::text, '')) = 'active';

-- Optional: verify Kamada bid
-- SELECT bid_id, player_id, seller_club_id, bidder_club_id, status
-- FROM public."Player_Transfer_Bids"
-- WHERE bid_id = 265;

NOTIFY pgrst, 'reload schema';
