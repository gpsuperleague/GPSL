-- Selling club can take a player off a listing that has not opened yet.
-- The squad page sets status to Closed. That update was granted, but row
-- security only allowed insert and read, so the change matched no rows and
-- the badge stayed on "Transfer listed — awaiting window".
-- Active auctions, bids, and underperformance listings stay blocked.

DROP POLICY IF EXISTS gpsl_seller_retract_pending_window
  ON public."Player_Transfer_Listings";

CREATE POLICY gpsl_seller_retract_pending_window
  ON public."Player_Transfer_Listings"
  FOR UPDATE
  TO authenticated
  USING (
    status = 'Pending Window'
    AND current_highest_bid IS NULL
    AND coalesce(transfer_completed, false) = false
    AND NOT coalesce(perpetual_renew, false)
    AND (
      public.is_gpsl_admin()
      OR EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE c."ShortName" = "Player_Transfer_Listings".seller_club_id
          AND c.owner_id = auth.uid()
      )
    )
  )
  WITH CHECK (
    status = 'Closed'
    AND coalesce(transfer_completed, false) = false
    AND current_highest_bid IS NULL
    AND NOT coalesce(perpetual_renew, false)
    AND (
      public.is_gpsl_admin()
      OR EXISTS (
        SELECT 1
        FROM public."Clubs" c
        WHERE c."ShortName" = "Player_Transfer_Listings".seller_club_id
          AND c.owner_id = auth.uid()
      )
    )
  );
