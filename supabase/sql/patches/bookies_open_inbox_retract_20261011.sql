-- =============================================================================
-- Retract the "Bookies is open" inbox message from every club's inbox.
-- Deletes all bookies_open messages. Safe re-run.
-- Note: re-running bookies_open_inbox_announce_20261011.sql afterwards would
-- send it again (the dedupe rows are gone).
-- =============================================================================

WITH gone AS (
  DELETE FROM public.competition_inbox
  WHERE message_type = 'bookies_open'
  RETURNING id
)
SELECT count(*) AS messages_retracted FROM gone;
