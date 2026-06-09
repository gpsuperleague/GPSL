-- =============================================================================
-- Manager draft bid columns on Manager_Transfer_Bids (safe re-run)
-- Run if manager draft page 400s on is_first_draft_bid / is_draft_join filters.
-- Full manager draft: also run managers_draft_auction.sql (guard + settlement).
-- =============================================================================

ALTER TABLE public."Manager_Transfer_Bids"
  ADD COLUMN IF NOT EXISTS is_first_draft_bid boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS is_draft_join boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS draft_join_consumed boolean NOT NULL DEFAULT false;

NOTIFY pgrst, 'reload schema';
