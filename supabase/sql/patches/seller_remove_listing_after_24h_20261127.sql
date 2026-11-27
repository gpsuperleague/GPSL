-- Seller can close their own active listing 24 hours after it opened,
-- when nobody has a live bid. The auction clock still ends at 19:00 UK
-- if they leave it up. Forced underperformance listings stay blocked.
-- Pending-window removal is unchanged. Safe re-run.

DROP POLICY IF EXISTS gpsl_seller_remove_after_24h
  ON public."Player_Transfer_Listings";

CREATE POLICY gpsl_seller_remove_after_24h
  ON public."Player_Transfer_Listings"
  FOR UPDATE
  TO authenticated
  USING (
    status = 'Active'
    AND current_highest_bid IS NULL
    AND coalesce(transfer_completed, false) = false
    AND NOT coalesce(perpetual_renew, false)
    AND coalesce(listing_type, 'standard') <> 'draft'
    AND now() >= coalesce(start_time, created_at) + interval '24 hours'
    AND NOT EXISTS (
      SELECT 1
      FROM public."Player_Transfer_Bids" b
      WHERE b.listing_id = "Player_Transfer_Listings".id
        AND lower(coalesce(b.status, 'active')) NOT IN ('rejected', 'cancelled')
    )
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
