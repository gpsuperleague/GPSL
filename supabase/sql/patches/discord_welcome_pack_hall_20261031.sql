-- Great Hall channel message ids on welcome_sent
ALTER TABLE public.gpsl_discord_welcome_sent
  ADD COLUMN IF NOT EXISTS hall_channel_id text,
  ADD COLUMN IF NOT EXISTS hall_message_id text;

NOTIFY pgrst, 'reload schema';
