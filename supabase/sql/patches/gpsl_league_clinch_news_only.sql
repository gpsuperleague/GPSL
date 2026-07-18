-- =============================================================================
-- Clinches → Discord #gpsl-news only (no notifications / tables)
-- Re-applies competition_process_league_clinches from the main patch.
-- Prefer re-running gpsl_league_clinch_announcements.sql instead if convenient.
-- Safe re-run.
-- =============================================================================

-- Cancel any still-pending clinch posts that were wrongly routed
UPDATE public.gpsl_discord_feed_queue q
SET status = 'skipped',
    last_error = left(
      coalesce(q.last_error, '') || ' [clinch now news-only]',
      500
    )
WHERE q.status IN ('pending', 'posting', 'error')
  AND (
    q.dedupe_key LIKE 'clinch_notify:%'
    OR q.dedupe_key LIKE 'clinch_tables:%'
  );

NOTIFY pgrst, 'reload schema';
