-- =============================================================================
-- Discord friendlies — stop re-notifying on every 2-minute poll
--
-- The ingest edge function was re-scanning recent messages and re-applying
-- ✅ reactions on already-ingested posts, which pinged posters every poll.
--
-- This adds a watermark column. Redeploy discord-friendlies-ingest after.
--
--   supabase functions deploy discord-friendlies-ingest
--
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.gpsl_discord_friendlies_settings
  ADD COLUMN IF NOT EXISTS last_ingested_message_id text;

COMMENT ON COLUMN public.gpsl_discord_friendlies_settings.last_ingested_message_id IS
  'Discord snowflake — friendlies ingest only fetches messages after this id.';
