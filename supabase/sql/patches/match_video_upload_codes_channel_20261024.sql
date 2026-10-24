-- =============================================================================
-- Match videos: remember Discord #upload-codes guide message id
-- Used by discord-match-videos-ingest mode=sync_codes
-- Safe re-run.
-- =============================================================================

ALTER TABLE public.gpsl_discord_match_videos_settings
  ADD COLUMN IF NOT EXISTS codes_channel_id text;

ALTER TABLE public.gpsl_discord_match_videos_settings
  ADD COLUMN IF NOT EXISTS codes_message_id text;

COMMENT ON COLUMN public.gpsl_discord_match_videos_settings.codes_channel_id IS
  'Discord channel id for the competition-codes guide (usually #upload-codes).';

COMMENT ON COLUMN public.gpsl_discord_match_videos_settings.codes_message_id IS
  'Discord message id of the posted/updated competition-codes embed.';
