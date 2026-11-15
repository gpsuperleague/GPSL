ALTER TABLE public.gpsl_pub_quiz_settings
  ADD COLUMN IF NOT EXISTS screen_message_id text,
  ADD COLUMN IF NOT EXISTS audio_message_id text;

SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'gpsl_pub_quiz_settings'
  AND column_name IN ('screen_message_id', 'audio_message_id')
ORDER BY column_name;
