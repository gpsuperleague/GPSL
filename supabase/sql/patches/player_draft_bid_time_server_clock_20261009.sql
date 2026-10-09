-- =============================================================================
-- Draft bids: server clock for bid_time + resync listing leaders (2026-10-09)
-- =============================================================================
-- The website stamped bid_time with the bidder's own PC clock, so a PC a
-- minute out shows bids out of order in the history (and could bid outside
-- the window). Draft bids now always take the database clock.
-- clock_timestamp() (not now()) so max-bid counter-bids placed in the same
-- transaction get increasing times and list in the right order.
--
-- Also re-syncs Player_Transfer_Listings.current_highest_bid/_bidder for live
-- draft listings to the real top bid.
-- Safe re-run.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.trg_player_transfer_bids_draft_server_time()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $function$
BEGIN
  IF NEW.is_direct IS TRUE AND NEW.seller_club_id IS NULL THEN
    NEW.bid_time := clock_timestamp();
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS player_transfer_bids_01_draft_server_time ON public."Player_Transfer_Bids";
CREATE TRIGGER player_transfer_bids_01_draft_server_time
  BEFORE INSERT ON public."Player_Transfer_Bids"
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_player_transfer_bids_draft_server_time();

-- ---------------------------------------------------------------------------
-- Resync live draft listings to their true top bid
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS _gpsl_draft_leader_resync;
CREATE TEMP TABLE _gpsl_draft_leader_resync AS
WITH b AS (
  SELECT * FROM public.draft_auction_window_bounds()
),
top AS (
  SELECT DISTINCT ON (coalesce(x.player_id, x.direct_bid_id::text))
    coalesce(x.player_id, x.direct_bid_id::text) AS player_id,
    x.bidder_club_id,
    x.bid_amount
  FROM public."Player_Transfer_Bids" x, b
  WHERE x.is_direct = true
    AND x.seller_club_id IS NULL
    AND b.draft_start IS NOT NULL
    AND x.bid_time >= b.draft_start
    AND x.bid_time < b.draft_window_end
  ORDER BY coalesce(x.player_id, x.direct_bid_id::text), x.bid_amount DESC, x.bid_time DESC
),
upd AS (
  UPDATE public."Player_Transfer_Listings" l
  SET current_highest_bid = t.bid_amount,
      current_highest_bidder = t.bidder_club_id
  FROM top t
  WHERE l.player_id = t.player_id
    AND l.listing_type = 'draft'
    AND l.status = 'Active'
    AND (
      l.current_highest_bidder IS DISTINCT FROM t.bidder_club_id
      OR l.current_highest_bid IS DISTINCT FROM t.bid_amount
    )
  RETURNING l.id, l.player_id, t.bidder_club_id AS leader_now, t.bid_amount
)
SELECT u.*, p."Name" AS player
FROM upd u
LEFT JOIN public."Players" p ON p."Konami_ID"::text = u.player_id;

NOTIFY pgrst, 'reload schema';

SELECT
  EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'player_transfer_bids_01_draft_server_time' AND NOT tgisinternal
  ) AS server_time_installed,
  (SELECT count(*) FROM _gpsl_draft_leader_resync) AS listings_resynced,
  (SELECT jsonb_agg(jsonb_build_object('player', player, 'leader', leader_now, 'bid', bid_amount))
     FROM _gpsl_draft_leader_resync) AS resynced;
