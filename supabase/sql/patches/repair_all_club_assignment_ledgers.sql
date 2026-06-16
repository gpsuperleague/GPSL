-- =============================================================================
-- One-time: post missing stadium purchase ledger lines for ALL assigned clubs
-- (balance already debited at auction — does not charge again)
-- Run after club_assignment_ledger_display.sql if only URD was repaired before.
-- =============================================================================

SELECT public.repair_club_assignment_ledger_only();
