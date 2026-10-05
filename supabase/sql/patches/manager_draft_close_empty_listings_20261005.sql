-- =============================================================================
-- Manager draft: close active draft listings that have no bids left
-- =============================================================================
-- Draft listings are only created on the first bid. After bids are withdrawn
-- (e.g. Cristo Valbuena), the empty listing still shows on
-- manager_draftauction.html. Closing it puts the manager back to "no auction";
-- the next bid creates a fresh listing via manager_draft_ensure_listing().
-- Safe re-run.
-- =============================================================================

WITH closed AS (
  UPDATE public."Manager_Transfer_Listings" l
  SET status = 'Closed',
      transfer_completed = false,
      current_highest_bid = NULL,
      current_highest_bidder = NULL,
      updated_at = now()
  WHERE l.listing_type = 'draft'
    AND l.status = 'Active'
    AND NOT EXISTS (
      SELECT 1 FROM public."Manager_Transfer_Bids" b WHERE b.listing_id = l.id
    )
  RETURNING l.id, l.manager_id
)
SELECT c.id AS closed_listing_id, m.name AS manager_name
FROM closed c
JOIN public."Managers" m ON m.id = c.manager_id
ORDER BY m.name;
